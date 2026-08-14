#!/bin/bash
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh" || {
    echo "Не найдена lib/common.sh — переустановите VSM: bash install.sh"; exit 1; }

# ----------------------------------------------------------------------
# TELEMT / MTPROTO: УПРАВЛЕНИЕ СТЕКОМ
# 3x-ui-pro + telemt (self-SNI маскировка) + telemt_panel + MEKO
# ----------------------------------------------------------------------

STACK_SCRIPT="$VSM_ROOT/stacks/telemt.sh"
REBUILD_SCRIPT="$VSM_ROOT/stacks/nginx-openssl35.sh"
STACK_CONF="/etc/vsm/telemt.conf"
STACK_CREDS="/etc/vsm/telemt-credentials.txt"

# Генератор self-SNI vhost общий с stacks/telemt.sh, он же задаёт MASK_VHOST.
# Раньше это были две копии одного heredoc, и одинаковый дефект приходилось
# бы чинить дважды.
if [ -f "$VSM_LIB/nginx_mask.sh" ]; then
    # shellcheck disable=SC1091
    source "$VSM_LIB/nginx_mask.sh"
else
    echo -e "${RED}❌ Не найден $VSM_LIB/nginx_mask.sh — обнови VSM (install.sh).${NC}"
    exit 1
fi

# Генератор блока доступа к telemt_panel через 443 домена панели — тоже общий
# с установщиком.
if [ -f "$VSM_LIB/nginx_panel_proxy.sh" ]; then
    # shellcheck disable=SC1091
    source "$VSM_LIB/nginx_panel_proxy.sh"
else
    echo -e "${RED}❌ Не найден $VSM_LIB/nginx_panel_proxy.sh — обнови VSM (install.sh).${NC}"
    exit 1
fi

# Тот же приём для MTProxyL-Panel, если она установлена. Строго ПОСЛЕ
# nginx_panel_proxy.sh: берёт оттуда общие strip/insert/apply_block.
if [ -f "$VSM_LIB/nginx_mtpl_proxy.sh" ]; then
    # shellcheck disable=SC1091
    source "$VSM_LIB/nginx_mtpl_proxy.sh"
fi

# Сторонний проект MTProxyL (лимитер | тюнинг) под Telemt. Пришёл на смену
# MTproxy-reanimation: тот заброшен на 1.2.9, разработка переехала в новый
# репозиторий. Лицензия MIT.
#
# Нам подходит ТОЛЬКО режим Reanimator: он применяет фиксы к чужой, уже
# работающей установке telemt — то есть к нашей. Режим Manager ставит Docker
# и поднимает СВОЙ telemt в контейнере на том же порту, что несовместимо со
# стеком VSM. Разница объясняется пользователю на экране пункта меню.
MTPROXYL_REPO="Liafanx/MTProxyL"
MTPROXYL_DIR="/opt/mtproxyl"
MTPROXYL_SETTINGS="$MTPROXYL_DIR/settings.conf"

# Следы прошлых поколений лимитера. Нужны только чтобы их заметить и
# предупредить о конфликте: правила у всех трёх поколений ограничивают один и
# тот же трафик, но лежат в разных таблицах и друг друга не вытесняют.
#
# MEKO — самое старое. У него ДВА режима SYN FIX:
#   iptables — цепочка MTPR_SYNFIX,     юнит mtpr-synfix.service
#   nftables — таблица inet mtpr_synfix, юнит mtpr-nft-synfix.service
MEKO_DIR="/opt/mtpr-simple"
MEKO_NFT_TABLE="mtpr_synfix"
MEKO_UNITS=(mtpr-synfix mtpr-nft-synfix)

# MTproxy-reanimation. Опаснее MEKO: его Zapret2 заворачивает трафик прокси в
# очередь nfqws, и второй такой же обработчик от MTProxyL встанет рядом — оба
# будут править одни и те же пакеты, а внешне это лишь необъяснимо плохое
# соединение. Таблица MTProto — именно zapret2, telemt_limit — SYN-лимитер.
# Семейство у таблиц разное, и хранится оно прямо в элементе массива: таблица
# inet не видна через `nft list table ip` и наоборот, поэтому одним семейством
# на всех не обойтись. Zapret2 (MTProto) автор создаёт в ip, а SYN-лимитер и
# iOS-фикс — в inet (mtpr.sh: nft add table ip / nft add table inet).
MTPR_DIR="/opt/mtproxy-reanimation"
MTPR_NFT_TABLES=(ip:MTProto inet:telemt_limit inet:mtpr_ios2_fix)
MTPR_UNITS=(mtpr-zapret2 mtpr-syn-limit)
MTPR_SYSCTL="/etc/sysctl.d/99-mtpr-meko-opt.conf"

function load_stack_conf {
    DOMAIN_PANEL=""; DOMAIN_REALITY=""
    TELEMT_PORT=""; TELEMT_MASK_PORT=""; PANEL_PORT=""; PANEL_PREFIX=""
    # Учётки тоже обнуляем перед чтением: «Удалить стек» умеет снести конфиг
    # прямо внутри цикла меню, и без сброса шапка продолжила бы показывать
    # логин и пароль от только что удалённой панели.
    PANEL_ADMIN_USER=""; PANEL_ADMIN_PASS=""
    if [ -f "$STACK_CONF" ]; then
        # shellcheck disable=SC1090
        source "$STACK_CONF"
    fi
}

function stack_status_line {
    if ! command -v telemt &> /dev/null && [ ! -f /etc/telemt/telemt.toml ]; then
        echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"
    elif systemctl is-active --quiet telemt; then
        echo -e "${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e "${YELLOW}ОСТАНОВЛЕН${NC}"
    fi
}

function panel_status_line {
    if [ ! -f /etc/telemt-panel/config.toml ]; then
        echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"
    elif systemctl is-active --quiet telemt-panel; then
        echo -e "${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e "${YELLOW}ОСТАНОВЛЕН${NC}"
    fi
}

function mask_status_line {
    if [ ! -f "$MASK_VHOST" ]; then
        echo -e "${RED}ОТСУТСТВУЕТ${NC}"
    else
        echo -e "${GREEN}НА МЕСТЕ${NC}"
    fi
}

# --- Запрос доменов у пользователя ---
function ask_domains {
    load_stack_conf
    echo -e "\n${CYAN}Стеку нужны ДВА разных поддомена, оба указывают на IP этого сервера:${NC}"
    echo -e "  • ${YELLOW}Домен панели${NC} — панель 3x-ui-pro, он же цель self-SNI маскировки"
    echo -e "  • ${YELLOW}Домен REALITY${NC} — ключ SNI-роутинга для REALITY"
    echo -e "${YELLOW}Домены обязаны отличаться, иначе nginx не примет конфиг.${NC}\n"

    read -p "Домен панели${DOMAIN_PANEL:+ [$DOMAIN_PANEL]}: " in_panel
    ASK_PANEL="${in_panel:-$DOMAIN_PANEL}"
    read -p "Домен REALITY${DOMAIN_REALITY:+ [$DOMAIN_REALITY]}: " in_reality
    ASK_REALITY="${in_reality:-$DOMAIN_REALITY}"

    if [ -z "$ASK_PANEL" ] || [ -z "$ASK_REALITY" ]; then
        echo -e "${RED}❌ Оба домена обязательны.${NC}"; return 1
    fi
    if [ "$ASK_PANEL" == "$ASK_REALITY" ]; then
        echo -e "${RED}❌ Домены должны быть разными.${NC}"; return 1
    fi
    return 0
}

function run_install {
    local mode="$1"
    [ -f "$STACK_SCRIPT" ] || { echo -e "${RED}❌ Не найден $STACK_SCRIPT${NC}"; read -p "Enter..."; return; }

    clear 2>/dev/null
    echo -e "${CYAN}======================================================${NC}"
    if [ "$mode" == "full" ]; then
        echo -e "${CYAN}     📦  УСТАНОВКА ВСЕГО СТЕКА С НУЛЯ  📦             ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${RED}❗  ВНИМАНИЕ: установщик 3x-ui-pro СТИРАЕТ существующую"
        echo -e "    панель — базу, инбаунды и всех пользователей.${NC}"
        if [ -d /etc/x-ui ]; then
            echo -e "${RED}❗  На сервере УЖЕ ЕСТЬ установленная 3x-ui (/etc/x-ui).${NC}"
            echo -e "${YELLOW}    Если она боевая — выбери вместо этого пункт 2"
            echo -e "    (добавить telemt к существующей панели).${NC}"
        fi
        echo ""
        read -p "$(echo -e "${RED}Введите СТЕРЕТЬ для подтверждения: ${NC}")" confirm
        if [ "$confirm" != "СТЕРЕТЬ" ]; then
            echo -e "${BLUE}Отменено.${NC}"; sleep 1; return
        fi
    else
        echo -e "${CYAN}   ➕  ДОБАВИТЬ telemt К СУЩЕСТВУЮЩЕЙ ПАНЕЛИ  ➕      ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${GREEN}Панель 3x-ui-pro не переустанавливается, база не трогается.${NC}"
        if [ ! -d /etc/x-ui ]; then
            echo -e "${RED}❌ 3x-ui-pro не установлена. Поставь её через пункт"
            echo -e "   'Управление X-UI' главного меню, затем вернись сюда.${NC}"
            read -p "Enter..."; return
        fi
    fi

    ask_domains || { read -p "Enter..."; return; }

    echo -e "\n${CYAN}Порты (Enter — значение по умолчанию):${NC}"
    read -p "Порт telemt [${TELEMT_PORT:-8444}]: " p_telemt
    read -p "Порт telemt_panel [${PANEL_PORT:-9444}]: " p_panel

    echo -e "\n${YELLOW}Запускаю установку. Это займёт несколько минут.${NC}\n"
    sleep 1

    DOMAIN_PANEL="$ASK_PANEL" \
    DOMAIN_REALITY="$ASK_REALITY" \
    TELEMT_PORT="${p_telemt:-${TELEMT_PORT:-8444}}" \
    PANEL_PORT="${p_panel:-${PANEL_PORT:-9444}}" \
        bash "$STACK_SCRIPT" --mode "$mode"

    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

function run_diagnostics {
    clear 2>/dev/null
    load_stack_conf
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}          🩺  СТАТУС И ДИАГНОСТИКА СТЕКА  🩺          ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    if [ ! -f "$STACK_CONF" ]; then
        echo -e "${YELLOW}Стек ещё не устанавливался через это меню.${NC}"
        read -p "Enter..."; return
    fi

    echo -e "Домен панели:   ${YELLOW}${DOMAIN_PANEL}${NC}"
    echo -e "Домен REALITY:  ${YELLOW}${DOMAIN_REALITY}${NC}"
    echo -e "${BLUE}------------------------------------------------------${NC}"
    echo -e "telemt:         [$(stack_status_line)]  порт ${TELEMT_PORT}"
    echo -e "telemt_panel:   [$(panel_status_line)]  порт ${PANEL_PORT}"
    echo -e "nginx:          [$(if systemctl is-active --quiet nginx; then echo -e "${GREEN}РАБОТАЕТ${NC}"; else echo -e "${RED}ОСТАНОВЛЕН${NC}"; fi)]"
    echo -e "x-ui:           [$(if systemctl is-active --quiet x-ui; then echo -e "${GREEN}РАБОТАЕТ${NC}"; else echo -e "${RED}ОСТАНОВЛЕН${NC}"; fi)]"
    echo -e "${BLUE}--- SELF-SNI МАСКИРОВКА ------------------------------${NC}"
    echo -e "vhost маскировки: [$(mask_status_line)]  ($MASK_VHOST)"

    if [ ! -f "$MASK_VHOST" ]; then
        echo -e "${RED}❗  Файл маскировки отсутствует!${NC}"
        echo -e "${YELLOW}    Скорее всего его стёрла переустановка или патч 3x-ui-pro."
        echo -e "    Без него telemt при DPI-пробе не отдаёт настоящий сайт."
        echo -e "    Почини пунктом 'Восстановить конфиги nginx'.${NC}"
    else
        echo -e "\n${CYAN}>>> Проверка локального vhost маскировки...${NC}"
        mask_code=$(curl -sk --max-time 5 --resolve "${DOMAIN_PANEL}:${TELEMT_MASK_PORT}:127.0.0.1" \
            "https://${DOMAIN_PANEL}:${TELEMT_MASK_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)
        if [ "$mask_code" == "200" ]; then
            echo -e "    ${GREEN}✓ vhost отвечает 200${NC}"
        else
            echo -e "    ${RED}✗ vhost вернул $mask_code (ожидалось 200)${NC}"
        fi

        echo -e "${CYAN}>>> Сквозной self-SNI тест через telemt...${NC}"
        e2e=$(curl -sk --max-time 8 "https://127.0.0.1:${TELEMT_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)
        if [ "$e2e" == "200" ]; then
            echo -e "    ${GREEN}✓ telemt отдаёт настоящий сайт при нераспознанном трафике${NC}"
        else
            echo -e "    ${RED}✗ вернулось $e2e вместо 200 — маскировка не работает${NC}"
            echo -e "    ${YELLOW}  journalctl -u telemt -n 50${NC}"
        fi
    fi

    echo -e "${BLUE}--- КОНФИГ TELEMT ------------------------------------${NC}"
    if [ -f /etc/telemt/telemt.toml ]; then
        # tls_domain здесь наравне с mask*: это цель self-SNI, и расхождение
        # её с доменом панели ломает маскировку так же надёжно, как выключенный
        # mask. Прежний фильтр её не захватывал, и в диагностике не было видно
        # половины сути.
        grep -E '^\[|^mask|^tls_domain' /etc/telemt/telemt.toml | sed 's/^/    /'
    fi

    # Сверка с реестром решений VSM. Здесь --dry-run: диагностика обязана
    # только показывать. Чинит сверка сама, но по расписанию сторожа, а не в
    # момент, когда человек пришёл посмотреть, что происходит.
    if [ -x "$VSM_ROOT/checks/drift.sh" ]; then
        bash "$VSM_ROOT/checks/drift.sh" --dry-run
    fi

    echo -e "${BLUE}------------------------------------------------------${NC}"
    read -p "Нажмите Enter для возврата..."
}

function restore_mask {
    load_stack_conf
    if [ ! -f "$STACK_CONF" ]; then
        echo -e "${RED}❌ Нет сохранённой конфигурации стека.${NC}"; read -p "Enter..."; return
    fi

    echo -e "\n${CYAN}>>> Восстановление self-SNI vhost...${NC}"

    # Сборка, проверка nginx -t и откат при неудаче — в lib/nginx_mask.sh,
    # общем с установщиком.
    local mask_ok=0 proxy_ok=0
    if nginx_mask_apply "$DOMAIN_PANEL" "$TELEMT_MASK_PORT"; then
        echo -e "${GREEN}✅ Маскировка восстановлена и nginx перезагружен.${NC}"
        mask_ok=1
    else
        echo -e "${RED}❌ Маскировка не восстановлена (причина выше).${NC}"
    fi

    # Блок доступа к telemt_panel восстанавливаем здесь же и по той же причине:
    # он живёт в vhost панели, а установщик и патч 3x-ui-pro вычищают
    # sites-enabled целиком. Маска это переживает (она в conf.d), а этот блок —
    # нет, и после каждого патча панель становилась бы недоступна снаружи.
    echo -e "\n${CYAN}>>> Восстановление доступа к telemt_panel...${NC}"
    if [ -z "$PANEL_PREFIX" ]; then
        # Конфиг от прежней версии, где панель висела на 0.0.0.0:9444. Префикс
        # генерируем сейчас и дописываем в конфиг — это и есть переезд.
        PANEL_PREFIX="$(panel_proxy_gen_prefix)"
        printf 'PANEL_PREFIX=%q\n' "$PANEL_PREFIX" >> "$STACK_CONF"
        echo -e "${YELLOW}    Префикс пути создан впервые — панель переезжает с порта ${PANEL_PORT} на 443.${NC}"
    fi
    # Серверная половина переезда обязательна и идёт ПЕРВОЙ: пока панель
    # слушает 0.0.0.0 и говорит по HTTPS, nginx ходит к ней по http:// и
    # получает 400, а vhost 3x-ui-pro переписывает это в 404.
    if ! panel_proxy_localize /etc/telemt-panel/config.toml \
            "${PANEL_PORT:-9444}" "$DOMAIN_REALITY"; then
        echo -e "${RED}❌ Не удалось перевести панель на loopback (причина выше).${NC}"
    fi

    local pv code
    if pv="$(nginx_mask_panel_vhost "$DOMAIN_PANEL")" && \
       panel_proxy_apply "$pv" "$PANEL_PREFIX" "${PANEL_PORT:-9444}"; then
        # Успех печатаем только по факту ответа, а не по коду применения
        # конфига. nginx принял файл — это ещё ничего не значит.
        code="$(panel_proxy_verify "$DOMAIN_PANEL" "$PANEL_PREFIX")" && proxy_ok=1
        if [ "$proxy_ok" = 1 ]; then
            echo -e "${GREEN}✅ Панель отвечает ($code): ${CYAN}https://${DOMAIN_PANEL}/${PANEL_PREFIX}/${NC}"
        else
            echo -e "${RED}❌ Блок в nginx применён, но панель по адресу вернула $code.${NC}"
            echo -e "${YELLOW}   Смотри journalctl -u telemt-panel и /var/log/nginx/error.log${NC}"
        fi
    else
        echo -e "${RED}❌ Доступ к telemt_panel не восстановлен (причина выше).${NC}"
    fi
    if [ "$proxy_ok" != 1 ]; then
        echo -e "${YELLOW}   Пока не починится — панель доступна через SSH-туннель:${NC}"
        echo -e "${YELLOW}   ssh -L ${PANEL_PORT:-9444}:127.0.0.1:${PANEL_PORT:-9444} root@<сервер>${NC}"
    fi

    # MTProxyL-Panel, если она установлена и спрятана за этот же домен.
    #
    # Идёт здесь, а не отдельным пунктом, ровно по той же причине, что и блок
    # telemt_panel: установщик и патч 3x-ui-pro вычищают vhost целиком, и после
    # каждого такого прохода доступ надо накладывать заново. Пункт меню один —
    # значит и восстанавливается всё одним действием, а не двумя, о втором из
    # которых легко забыть.
    mtpl_restore_proxy

    [ "$mask_ok" = 1 ] && [ "$proxy_ok" = 1 ] || \
        echo -e "\n${YELLOW}Не всё восстановлено — прогони «Статус и диагностика».${NC}"
    read -p "Нажмите Enter..."
}

# ----------------------------------------------------------------------
# Доступ к MTProxyL-Panel по секретному префиксу на 443 домена панели.
#
# Молчит, если панели нет: это необязательный сторонний компонент, и сообщать
# о его отсутствии на каждом восстановлении маски незачем.
# ----------------------------------------------------------------------
function mtpl_restore_proxy {
    command -v mtpl_proxy_apply >/dev/null 2>&1 || return 0
    [ -f "$MTPL_PANEL_CONF" ] || return 0
    [ -f /usr/local/bin/mtproxyl-panel ] || return 0

    local prefix port pv code
    prefix="$(mtpl_panel_prefix)"
    port="$(mtpl_panel_port)"

    echo -e "\n${CYAN}>>> Восстановление доступа к MTProxyL-Panel...${NC}"

    if [ -z "$prefix" ] || [ -z "$port" ]; then
        echo -e "${YELLOW}   В ${MTPL_PANEL_CONF} не задан base_path или listen —${NC}"
        echo -e "${YELLOW}   отдавать нечего. Настройте панель и повторите.${NC}"
        return 0
    fi
    # Прятать за префикс панель, которая и сама висит наружу, бессмысленно:
    # секретный путь не закрывает открытый порт.
    if ! mtpl_panel_is_local; then
        echo -e "${RED}❗  Панель слушает не только 127.0.0.1 — секретный префикс её не спрячет.${NC}"
        echo -e "${YELLOW}   Поправьте listen в ${MTPL_PANEL_CONF} на 127.0.0.1 и повторите.${NC}"
        return 0
    fi

    if pv="$(nginx_mask_panel_vhost "$DOMAIN_PANEL")" && \
       mtpl_proxy_apply "$pv" "$prefix" "$port"; then
        # Как и у telemt_panel: успех печатаем по ответу, а не по тому, что
        # nginx принял файл.
        if code="$(panel_proxy_verify "$DOMAIN_PANEL" "$prefix")"; then
            echo -e "${GREEN}✅ MTProxyL-Panel отвечает ($code):${NC}"
            echo -e "   ${CYAN}https://${DOMAIN_PANEL}/${prefix}/${NC}"
        else
            echo -e "${RED}❌ Блок применён, но панель по адресу вернула $code.${NC}"
            echo -e "${YELLOW}   Проверьте, что base_path в конфиге панели равен ${prefix}.${NC}"
        fi
    else
        echo -e "${RED}❌ Доступ к MTProxyL-Panel не подключён (причина выше).${NC}"
    fi
}

# ----------------------------------------------------------------------
# Сверка TLS-параметров маски и панели + проверка постквантового обмена.
#
# Зачем отдельный пункт. «Статус и диагностика» судит по HTTP-коду 200, а это
# слабый признак: маска может отвечать 200, отдавая при этом другой сертификат,
# другой набор шифров или другую группу обмена ключами. Для активного пробера
# достаточно одного расхождения — он сравнивает два порта одного IP и видит,
# что за ними разные TLS-стеки, чего у одного сайта быть не может.
#
# Идея проверки на PQ взята из MTProxyL (пункт «Проверить текущий SNI-домен на
# PQ»), но там она сводится к одному вопросу «поддерживается ли X25519MLKEM768».
# Нам важнее паритет: PQ, включённый на панели и не включённый на маске, хуже,
# чем отсутствие PQ на обеих.
#
# Системный openssl на Ubuntu 24.04 — 3.0, он группу X25519MLKEM768 даже
# запросить не может. Поэтому PQ-часть выполняется только при наличии
# openssl 3.5+: наш /opt/openssl-3.5 после пересборки nginx либо сборка
# MTProxyL, если он установлен.
# ----------------------------------------------------------------------
# Снимок рукопожатия во ВРЕМЕННЫЙ ФАЙЛ, а не в переменную.
#
# Вывод s_client содержит нулевые байты, и подстановка команды их выбрасывает с
# предупреждением bash. Попытка убрать их через `tr -d '\0'` делает хуже:
# проверено на стенде — после неё перестают находиться и Protocol, и Cipher,
# то есть поля молча оказываются пустыми. Файл снимает вопрос целиком, а заодно
# сокращает число вызовов openssl с десяти до двух: один снимок на порт.
function _tls_dump {
    local port="$1" domain="$2" out="$3"
    # Пауза перед EOF обязательна. Блок SSL-Session, где лежат Protocol и
    # Cipher, печатается при закрытии соединения, а голый `echo |` закрывает
    # stdin мгновенно — s_client успевает выйти раньше, чем блок появится.
    # Замер на стенде, по 8 попыток на порт: с голым echo полными оказались
    # 5 дампов из 8 на КАЖДОМ порту, с паузой — 8 из 8.
    #
    # Цена дефекта была не в пустых полях, а в выводе: пустое значение на
    # одном порту против заполненного на другом читается ниже как
    # РАСХОЖДЕНИЕ. При независимых 5/8 ровно один порт обрезается почти в
    # половине запусков — то есть пункт регулярно поднимал ложную тревогу
    # сразу по двум полям и предлагал чинить исправную маскировку.
    { echo; sleep 1; } | timeout 10 openssl s_client -connect "127.0.0.1:${port}" \
        -servername "$domain" -alpn h2,http/1.1 > "$out" 2>/dev/null
}

function _tls_field {
    local file="$1" field="$2"
    [ -s "$file" ] || return 0
    case "$field" in
        fp)     openssl x509 -noout -fingerprint -sha256 -in "$file" 2>/dev/null | cut -d= -f2 ;;
        proto)  grep -a -m1 -oP '^\s*Protocol\s*:\s*\K.*' "$file" | tr -d ' ' ;;
        cipher) grep -a -m1 -oP '^\s*Cipher\s*:\s*\K.*' "$file" | tr -d ' ' ;;
        group)  grep -a -m1 -oP 'Server Temp Key:\s*\K.*' "$file" ;;
        alpn)   grep -a -m1 -oP 'ALPN protocol:\s*\K.*' "$file" ;;
    esac
}

function _pq_openssl_bin {
    local c
    for c in /opt/openssl-3.5/bin/openssl /opt/mtproxyl-nginx/bin/openssl \
             /opt/mtproxyl-nginx/sbin/openssl; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

function check_tls_parity {
    clear 2>/dev/null
    load_stack_conf
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       🔬  СВЕРКА TLS: МАСКА ПРОТИВ ПАНЕЛИ  🔬        ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    if [ -z "$DOMAIN_PANEL" ]; then
        echo -e "${RED}❌ Конфиг стека не найден — сверять нечего.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    local mp="${TELEMT_MASK_PORT:-7444}"
    echo -e "  Домен: ${YELLOW}$(_addr_clean "$DOMAIN_PANEL")${NC}"
    echo -e "  Маска: ${YELLOW}127.0.0.1:${mp}${NC}   Панель: ${YELLOW}127.0.0.1:443${NC}\n"

    local dm dp
    dm=$(mktemp /tmp/vsm-tls-mask.XXXXXX); dp=$(mktemp /tmp/vsm-tls-panel.XXXXXX)
    trap 'rm -f "$dm" "$dp"' RETURN
    _tls_dump "$mp" "$DOMAIN_PANEL" "$dm"
    _tls_dump 443    "$DOMAIN_PANEL" "$dp"

    local diff=0 f
    for f in fp proto cipher group alpn; do
        local a b label
        a=$(_tls_field "$dm" "$f")
        b=$(_tls_field "$dp" "$f")
        case "$f" in
            fp)     label="Отпечаток" ;;
            proto)  label="Протокол" ;;
            cipher) label="Шифр" ;;
            group)  label="Группа обмена" ;;
            alpn)   label="ALPN" ;;
        esac
        if [ -z "$a" ] && [ -z "$b" ]; then
            printf "  %-16s ${YELLOW}%s${NC}\n" "$label" "нет данных с обоих портов"
        elif [ "$a" = "$b" ]; then
            printf "  %-16s ${GREEN}совпадает${NC}  %s\n" "$label" "$a"
        else
            printf "  %-16s ${RED}РАСХОЖДЕНИЕ${NC}\n" "$label"
            printf "  %-16s   маска : %s\n" "" "${a:-нет ответа}"
            printf "  %-16s   панель: %s\n" "" "${b:-нет ответа}"
            diff=$((diff + 1))
        fi
    done

    echo
    echo -e "${BLUE}--- Постквантовый обмен (X25519MLKEM768) -------------${NC}"
    local pq
    if pq=$(_pq_openssl_bin); then
        echo -e "  Проверяю через ${CYAN}${pq}${NC}"
        local p ok_pq=0
        for p in "$mp" 443; do
            local r
            # Пауза перед EOF по той же причине, что и в _tls_dump: дамп не
            # должен обрываться раньше, чем допечатаются поля о соединении.
            r=$({ echo; sleep 1; } | timeout 10 "$pq" s_client -tls1_3 -groups X25519MLKEM768 \
                  -connect "127.0.0.1:${p}" -servername "$DOMAIN_PANEL" 2>&1)
            if printf '%s' "$r" | grep -q 'X25519MLKEM768'; then
                printf "  порт %-5s ${GREEN}PQ активен${NC}\n" "$p"; ok_pq=$((ok_pq + 1))
            else
                printf "  порт %-5s ${YELLOW}PQ не согласован${NC}\n" "$p"
            fi
        done
        # Паритет важнее самого PQ: включённый на одном порту и выключенный на
        # другом — это признак, которого без PQ вовсе не было бы.
        if [ "$ok_pq" = 1 ]; then
            echo -e "  ${RED}❗  PQ работает только на ОДНОМ порту — это расхождение.${NC}"
            diff=$((diff + 1))
        fi
    else
        echo -e "  ${YELLOW}Пропущено: нужен openssl 3.5+.${NC}"
        echo -e "  ${BLUE}Системный $(openssl version 2>/dev/null | awk '{print $2}') группу X25519MLKEM768 не поддерживает.${NC}"
        echo -e "  ${BLUE}Появится после пункта «Пересборка nginx с OpenSSL 3.5».${NC}"
    fi

    echo
    if [ "$diff" -eq 0 ]; then
        echo -e "${GREEN}✅ Расхождений нет — маска неотличима от панели по этим признакам.${NC}"
    else
        echo -e "${RED}❌ Расхождений: ${diff}. Каждое — признак для активного пробера.${NC}"
        echo -e "${YELLOW}   Почини пунктом «Восстановить конфиги nginx».${NC}"
    fi
    read -p "Нажмите Enter..."
}

function show_credentials {
    clear 2>/dev/null
    if [ ! -f "$STACK_CREDS" ]; then
        echo -e "${RED}❌ Файл учётных данных не найден ($STACK_CREDS).${NC}"
    else
        ui_title "🔑  УЧЁТНЫЕ ДАННЫЕ СТЕКА"
        echo ""
        # Адрес панели считаем живьём, а строку из файла подменяем. Причин две.
        # Первая: файл пишется один раз при установке и устаревает, как только
        # панель сменит webBasePath — а его меняет и патч, и переустановка.
        # Вторая: там короткая форма без panel/, и она расходилась с шапками
        # меню, где адрес всегда собирал xui_panel_url. Подмена на лету чинит
        # расхождение и на серверах, где файл записан давно.
        #
        # Не sed: адрес попал бы в правую часть замены, где & и разделитель
        # имеют особый смысл.
        local live_url line; live_url=$(xui_panel_url)
        # "|| [ -n "$line" ]" — чтобы не потерять последнюю строку файла, если
        # он остался без завершающего перевода строки после правки руками.
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "Панель 3x-ui-pro:"*)
                    [ -n "$live_url" ] && line="Панель 3x-ui-pro:   $live_url" ;;
            esac
            # Значения — жирным, подписи — обычным.
            #
            # Это ЕДИНСТВЕННЫЙ экран, ради которого сюда заходят, и до правки
            # оформления он остался нетронутым: файл печатался как есть, без
            # выделения вообще. Заявление «учётные данные теперь жирным» до
            # него не доходило — нашлось перепроверкой готовой работы, а не
            # при её выполнении.
            #
            # printf с %b для цвета и %s для значения: строка приходит из файла
            # на диске, и разворачивать в ней escape-последовательности нельзя.
            case "$line" in
                *:*)
                    printf '   %b%s:%b%b%s%b\n' \
                        "$C_NAME" "${line%%:*}" "$NC" \
                        "$C_SECRET" "${line#*:}" "$NC" ;;
                *)  printf '   %s\n' "$line" ;;
            esac
        done < "$STACK_CREDS"
        echo ""
        ui_kv '📄  Файл' "$STACK_CREDS (права 600)" 17
    fi
    read -p "Нажмите Enter..."
}

function manage_services {
    while true; do
        clear 2>/dev/null
        echo -e "${CYAN}--- 🔧  УПРАВЛЕНИЕ СЛУЖБАМИ СТЕКА --------------------${NC}"
        echo -e "    telemt:       [$(stack_status_line)]"
        echo -e "    telemt_panel: [$(panel_status_line)]"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "1) 📊   Служба telemt (статус | старт | стоп | логи)"
        echo -e "2) 💻   Служба telemt_panel (статус | старт | стоп | логи)"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        read -p "Выбор: " s_choice
        case $s_choice in
            1) manage_service_status_restart telemt ;;
            2) manage_service_status_restart telemt-panel ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

# Версия установленной копии — из объявления VERSION в самом скрипте.
# Шаблон намеренно нестрогий: это чужой файл, и оформление строки там может
# смениться на одинарные кавычки, readonly или отступ. Жёсткий шаблон в таком
# случае молча вернул бы пустоту, и меню показывало бы «не установлен» рядом с
# работающим инструментом.
function mtproxyl_installed_version {
    [ -f "$MTPROXYL_DIR/mtproxyl.sh" ] || return 1
    grep -m1 -oE '^[[:space:]]*(readonly[[:space:]]+)?VERSION=["'"'"']?[0-9]+(\.[0-9]+)+' \
        "$MTPROXYL_DIR/mtproxyl.sh" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+'
}

# Версия у автора. Отдельный файл version в репозитории — по нему же
# сверяется и сам mtproxyl при запуске. Молча пусто, если сети нет.
function mtproxyl_latest_version {
    curl -fsS --max-time 6 "https://raw.githubusercontent.com/$MTPROXYL_REPO/main/version" 2>/dev/null \
        | tr -d '[:space:]'
}

# Установлен ли MTProxyL. Смотрим оба признака: каталог автора и команду в
# PATH. Файл есть, а команды нет — установка оборвалась на полпути; команда
# есть, а каталога нет — инструмент поставили в обход нашего пункта. В обоих
# случаях считаем установленным: предлагать поставить то, что уже стоит, хуже,
# чем лишний раз показать «установлен».
function mtproxyl_is_installed {
    [ -f "$MTPROXYL_DIR/mtproxyl.sh" ] || command -v mtproxyl &> /dev/null
}

# Выбранный режим работы: manager или reanimator. Читаем grep'ом, а не source:
# файл чужой, и исполнять его содержимое в своей оболочке незачем. Пусто, если
# режим ещё не выбран — например, установку прервали на первом вопросе.
function mtproxyl_mode {
    [ -f "$MTPROXYL_SETTINGS" ] || return 1
    grep -m1 -oE "^[[:space:]]*MTPROXYL_MODE=['\"]?[a-z]+" "$MTPROXYL_SETTINGS" 2>/dev/null \
        | grep -oE '[a-z]+$'
}

# Строка состояния для шапки меню. Сеть здесь не трогаем намеренно: шапка
# перерисовывается при каждом возврате в меню, и сверка версии с GitHub
# подвешивала бы её на таймаут всякий раз, когда сети нет.
function mtproxyl_status_line {
    local ver mode
    if ! mtproxyl_is_installed; then
        echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"
        return
    fi
    ver=$(mtproxyl_installed_version 2>/dev/null)
    mode=$(mtproxyl_mode 2>/dev/null)
    # Manager подсвечивается жёлтым: он означает второй, чужой telemt рядом с
    # нашим — состояние рабочее, но почти наверняка выбранное по ошибке.
    case "$mode" in
        reanimator) echo -e "${GREEN}УСТАНОВЛЕН${ver:+ v$ver}${NC} ${GREEN}(Reanimator)${NC}" ;;
        manager)    echo -e "${GREEN}УСТАНОВЛЕН${ver:+ v$ver}${NC} ${YELLOW}(Manager — см. пункт 7)${NC}" ;;
        *)          echo -e "${GREEN}УСТАНОВЛЕН${ver:+ v$ver}${NC}" ;;
    esac
}

# Следы прошлых поколений лимитера — MEKO и MTproxy-reanimation. Признаки
# каждого проверяются независимо и по нескольким сразу: остатки бывают и без
# самого менеджера, если каталог удалили вручную, а служба и таблица уцелели.
# Возвращает 1, если что-то найдено, — вызывающий по этому коду не судит,
# предупреждение носит рекомендательный характер.
function legacy_leftovers_warning {
    local meko="" mtpr="" u t

    # --- MEKO: оба его режима SYN FIX ---
    command -v mekopr &>/dev/null && meko="команда mekopr"
    [ -d "$MEKO_DIR" ] && meko="${meko:+$meko, }каталог $MEKO_DIR"
    if iptables-save 2>/dev/null | grep -qiE "meko|synfix"; then
        meko="${meko:+$meko, }цепочка в iptables"
    fi
    if nft list table inet "$MEKO_NFT_TABLE" &>/dev/null; then
        meko="${meko:+$meko, }nft-таблица $MEKO_NFT_TABLE"
    fi
    for u in "${MEKO_UNITS[@]}"; do
        [ -f "/etc/systemd/system/$u.service" ] && meko="${meko:+$meko, }служба $u"
    done

    # --- MTproxy-reanimation: zapret2, SYN-лимитер, iOS-фикс, sysctl ---
    command -v mtpr &>/dev/null && mtpr="команда mtpr"
    [ -d "$MTPR_DIR" ] && mtpr="${mtpr:+$mtpr, }каталог $MTPR_DIR"
    for t in "${MTPR_NFT_TABLES[@]}"; do
        nft list table "${t%%:*}" "${t#*:}" &>/dev/null \
            && mtpr="${mtpr:+$mtpr, }nft-таблица ${t#*:}"
    done
    for u in "${MTPR_UNITS[@]}"; do
        [ -f "/etc/systemd/system/$u.service" ] && mtpr="${mtpr:+$mtpr, }служба $u"
    done
    [ -f "$MTPR_SYSCTL" ] && mtpr="${mtpr:+$mtpr, }sysctl $MTPR_SYSCTL"

    [ -z "$meko" ] && [ -z "$mtpr" ] && return 0

    if [ -n "$mtpr" ]; then
        echo -e "${RED}❗  Найдены следы MTproxy-reanimation ($mtpr).${NC}"
        echo -e "${YELLOW}   Это предыдущее поколение того же инструмента, и оно ограничивает"
        echo -e "   тот же трафик. Хуже всего с Zapret2: он заворачивает пакеты прокси"
        echo -e "   в очередь nfqws, а такой же обработчик MTProxyL встанет рядом —"
        echo -e "   оба будут править одни и те же пакеты."
        echo -e "   Сначала снимите старый: ${CYAN}mtpr${YELLOW} → пункт «[u] Удалить»."
        echo -e "   Оно само откатит sysctl и уберёт правила.${NC}\n"
    fi

    if [ -n "$meko" ]; then
        echo -e "${RED}❗  Найдены следы MEKO ($meko).${NC}"
        echo -e "${YELLOW}   MEKO ставит SYN FIX либо в iptables, либо в nftables — в обоих"
        echo -e "   случаях он ограничивает тот же трафик, что и MTProxyL."
        echo -e "   Сначала снимите его: ${CYAN}mekopr${YELLOW} → «Удалить SYN FIX»,"
        echo -e "   затем «Удалить MEKO Manager».${NC}\n"
    fi
    return 1
}

function run_mtproxyl {
    clear 2>/dev/null
    load_stack_conf
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}      🔒  MTPROXYL — SYN-ЛИМИТЕР И ТЮНИНГ  🔒         ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    # Пункты чужого меню здесь намеренно не перечисляются: они зависят от
    # состояния сервера и меняются с обновлениями. Любая шпаргалка устареет.
    echo -e "${YELLOW}Сторонний интерактивный менеджер под Telemt: SYN-лимитер на"
    echo -e "nftables, обход Zapret2, тюнинг sysctl, фиксы для iOS."
    echo -e "Он покажет своё меню.${NC}\n"

    local inst latest mode
    inst=$(mtproxyl_installed_version)
    latest=$(mtproxyl_latest_version)
    mode=$(mtproxyl_mode)
    echo -e "${GREEN}Версии:${NC}"
    echo -e "  установлена:      ${CYAN}${inst:-не установлен}${NC}"
    echo -e "  доступна:         ${CYAN}${latest:-не удалось проверить}${NC}"
    if [ -n "$inst" ] && [ -n "$latest" ] && [ "$inst" != "$latest" ]; then
        echo -e "  ${YELLOW}↑ Есть обновление. mtproxyl предложит его при запуске.${NC}"
    fi
    echo -e "  режим:            ${CYAN}${mode:-не выбран}${NC}"
    echo -e "  порт telemt:      ${CYAN}${TELEMT_PORT:-8444}${NC}\n"

    # Главное, что нужно знать до первого запуска: у MTProxyL два режима, и
    # только один из них совместим со стеком VSM. Спрашивают об этом первым же
    # вопросом установщика, поэтому предупреждаем заранее.
    if ! mtproxyl_is_installed; then
        echo -e "${RED}❗  ВАЖНО: на первом вопросе выберите режим [2] Reanimator.${NC}"
        echo -e "${YELLOW}   Reanimator применяет фиксы к УЖЕ работающему telemt — к тому,"
        echo -e "   который поставил VSM. Ничего не устанавливает и не перезаписывает."
        echo -e "   Режим [1] Manager поставит Docker и поднимет ВТОРОЙ telemt в"
        echo -e "   контейнере на этом же порту — со стеком VSM он несовместим.${NC}\n"
    fi

    # Своя маскировка у MTProxyL правит те же ключи [censorship], которыми
    # управляет self-SNI маскировка VSM. Пункт 4 будет возвращать их обратно,
    # и вдвоём они устроят качели.
    echo -e "${RED}❗  Selfmask в его меню — не включайте.${NC}"
    echo -e "${YELLOW}   Маскировку в этой сборке держит VSM (пункт 4), а Selfmask"
    echo -e "   переставит tls_domain, mask_host и mask_port на свой nginx."
    echo -e "   Постквантовый TLS для маскировки — это пункт 8, ещё один"
    echo -e "   PQ-nginx рядом не нужен.${NC}\n"

    echo -e "${YELLOW}Код скачивается с GitHub автора и выполняется от root."
    echo -e "Репозиторий не наш (лицензия MIT), содержимое может меняться.${NC}\n"

    legacy_leftovers_warning

    if command -v docker &> /dev/null; then
        echo -e "${YELLOW}❗  Обнаружен Docker. После применения правил проверьте"
        echo -e "    порядок цепочек: ${CYAN}nft list ruleset${YELLOW} — правило должно"
        echo -e "    отрабатывать раньше цепочек Docker.${NC}\n"
    fi

    echo -e "${BLUE}------------------------------------------------------${NC}"
    # Вопрос зависит от состояния: при установленном инструменте пункт его НЕ
    # переустанавливает, а просто открывает. Прежняя формулировка «Установить и
    # запустить» этого не показывала, и выглядело так, будто установка идёт по
    # кругу.
    if mtproxyl_is_installed; then
        read -p "$(echo -e "${CYAN}Открыть менеджер mtproxyl? [y/N]: ${NC}")" go
    else
        read -p "$(echo -e "${CYAN}Установить и запустить MTProxyL? [y/N]: ${NC}")" go
    fi
    if [[ ! "$go" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Отменено.${NC}"; sleep 1; return
    fi

    # Установщик автора заканчивается exec-ом самого mtproxyl, то есть меню
    # открывается уже в ходе установки. Поэтому запускаем инструмент сами
    # только когда он был установлен ЗАРАНЕЕ — иначе показали бы его дважды.
    local was_installed=0
    command -v mtproxyl &> /dev/null && was_installed=1

    if [ "$was_installed" -eq 0 ]; then
        echo -e "${CYAN}>>> Устанавливаю MTProxyL...${NC}"
        run_remote_script "https://raw.githubusercontent.com/$MTPROXYL_REPO/main/install.sh"
    else
        echo -e "${GREEN}>>> Запускаю mtproxyl (выход из него вернёт сюда)...${NC}"
        sleep 1
        mtproxyl
    fi

    if command -v mtproxyl &> /dev/null; then
        # Проверка нужна и после установки: если автор уберёт exec из своего
        # установщика, инструмент поставится, но не откроется — и без этой
        # подсказки было бы непонятно, произошло ли вообще что-нибудь.
        [ "$was_installed" -eq 0 ] && \
            echo -e "${GREEN}✅ Установлено. Открыть менеджер снова — этот же пункт меню.${NC}"
        # Режим проверяем после ЛЮБОГО запуска, а не только после установки:
        # переключить его можно и из чужого меню, уже после нашего экрана.
        if [ "$(mtproxyl_mode)" = "manager" ]; then
            echo -e "\n${RED}❗  Выбран режим Manager — он несовместим со стеком VSM.${NC}"
            echo -e "${YELLOW}   Сейчас на сервере два telemt: наш и его контейнер."
            echo -e "   Переключить: ${CYAN}mtproxyl mode reanimator${YELLOW}"
            echo -e "   При переходе он предложит остановить и удалить свой контейнер —"
            echo -e "   соглашайтесь, иначе тот продолжит держать порт.${NC}"
        fi
    else
        echo -e "${RED}❌ Команда mtproxyl не появилась — установка не удалась.${NC}"
        echo -e "${YELLOW}   Проверьте доступ к GitHub и повторите.${NC}"
    fi
    read -p "Нажмите Enter для возврата..."
}

function run_rebuild_nginx {
    clear 2>/dev/null
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}    🔬  ПЕРЕСБОРКА NGINX С OPENSSL 3.5 (PQ TLS)  🔬   ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "Системный OpenSSL 3.0.x не умеет постквантовый обмен ключей"
    echo -e "(X25519MLKEM768). Клиенты iOS его предпочитают, и его отсутствие"
    echo -e "на self-SNI backend'е — заметный маркер для DPI-эвристик.\n"
    echo -e "${RED}❗  Операция долгая: 20-40 минут на 1 vCPU.${NC}"
    echo -e "${RED}❗  Подменяется системный бинарник nginx (с бэкапом и авто-откатом).${NC}"
    echo -e "${RED}❗  После неё пакет nginx замораживается (apt-mark hold) —"
    echo -e "    security-обновления придётся ставить вручную.${NC}\n"

    if [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ]; then
        echo -e "${YELLOW}❗  Ты НЕ в tmux/screen. Обрыв SSH прервёт сборку на середине.${NC}"
        echo -e "${YELLOW}    Рекомендую: tmux new -s nginx, затем вернуться сюда.${NC}\n"
    else
        echo -e "${GREEN}✓ Сессия в tmux/screen — обрыв SSH сборку не убьёт.${NC}\n"
    fi

    [ -f "$REBUILD_SCRIPT" ] || { echo -e "${RED}❌ Не найден $REBUILD_SCRIPT${NC}"; read -p "Enter..."; return; }

    read -p "$(echo -e "${RED}Введите СОБРАТЬ для подтверждения: ${NC}")" confirm
    if [ "$confirm" != "СОБРАТЬ" ]; then
        echo -e "${BLUE}Отменено.${NC}"; sleep 1; return
    fi

    # Код возврата читаем. Прежде результат скрипта не смотрели вовсе: после
    # 20-40 минут сборки экран выглядел одинаково и при успехе, и при откате.
    # Цена ошибки здесь — лежащий прокси: остановка nginx внутри скрипта
    # уносит telemt по Requires=nginx.service (инвариант 2).
    local rc=0
    bash "$REBUILD_SCRIPT" || rc=$?

    echo
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}✅ Скрипт завершился успешно (код 0).${NC}"
    else
        echo -e "${RED}❌ Скрипт завершился с кодом ${rc}.${NC}"
        echo -e "${YELLOW}   Откат он делает сам, но проверьте состояние ниже:"
        echo -e "   стек мог остаться без telemt.${NC}"
    fi

    # Показываем факт, а не пересказ вывода скрипта. Именно здесь исторически
    # печаталось зелёное «Готово» над остановленным прокси.
    local nginx_line
    if systemctl is-active --quiet nginx; then
        nginx_line="${GREEN}РАБОТАЕТ${NC}"
    else
        nginx_line="${RED}ОСТАНОВЛЕН${NC}"
    fi
    echo -e "\n${CYAN}Состояние стека:${NC}"
    echo -e "  nginx:        ${nginx_line}"
    echo -e "  telemt:       $(stack_status_line)"
    echo -e "  telemt-panel: $(panel_status_line)"

    if [ "$rc" -eq 0 ]; then
        echo -e "\n${BLUE}Дальше — пункт 5 «Сверить TLS маски и панели»: после удачной"
        echo -e "пересборки он начинает проверять и постквантовый обмен, и требует,"
        echo -e "чтобы PQ был согласован на ОБОИХ портах.${NC}"
    fi
    read -p "Нажмите Enter для возврата..."
}

function uninstall_stack {
    clear 2>/dev/null
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}          🧨   УДАЛЕНИЕ СТЕКА TELEMT  🧨              ${NC}"
    echo -e "${RED}======================================================${NC}"
    echo -e "${YELLOW}Будут удалены: telemt, telemt_panel, их конфиги и данные,"
    echo -e "vhost маскировки, правила UFW для портов стека.${NC}"
    echo -e "${GREEN}3x-ui-pro, nginx и сертификаты НЕ трогаются.${NC}\n"
    read -p "$(echo -e "${RED}Введите УДАЛИТЬ для подтверждения: ${NC}")" confirm
    if [ "$confirm" != "УДАЛИТЬ" ]; then
        echo -e "${BLUE}Отменено.${NC}"; sleep 1; return
    fi

    load_stack_conf

    echo -e "${YELLOW}>>> Остановка служб...${NC}"
    systemctl disable --now telemt-panel &>/dev/null || true
    systemctl disable --now telemt &>/dev/null || true

    echo -e "${YELLOW}>>> Удаление файлов...${NC}"
    rm -rf /etc/telemt /etc/telemt-panel
    rm -rf /etc/systemd/system/telemt.service.d
    rm -f /etc/systemd/system/telemt.service /etc/systemd/system/telemt-panel.service
    rm -f /usr/bin/telemt /usr/local/bin/telemt /bin/telemt
    rm -f /usr/bin/telemt-panel /usr/local/bin/telemt-panel
    rm -f "$MASK_VHOST"
    systemctl daemon-reload

    if command -v ufw &> /dev/null; then
        [ -n "$TELEMT_PORT" ] && ufw delete allow "${TELEMT_PORT}/tcp" &>/dev/null || true
        [ -n "$PANEL_PORT" ]  && ufw delete allow "${PANEL_PORT}/tcp"  &>/dev/null || true
    fi

    if nginx -t &>/dev/null; then
        systemctl reload nginx
        echo -e "${GREEN}✓ nginx перезагружен без vhost маскировки.${NC}"
    else
        echo -e "${RED}❗  nginx -t не проходит — проверь конфиг вручную.${NC}"
    fi

    # Блок доступа к панели вписан в vhost 3x-ui, а сам vhost мы не трогаем —
    # значит, снять блок обязаны здесь, иначе в конфиге останется proxy_pass на
    # порт, который больше никто не слушает.
    if [ -n "$DOMAIN_PANEL" ]; then
        local pv
        if pv="$(nginx_mask_panel_vhost "$DOMAIN_PANEL" 2>/dev/null)" && panel_proxy_remove "$pv"; then
            echo -e "${GREEN}✓ Блок доступа к telemt_panel снят из vhost панели.${NC}"
        fi
    fi
    # И доступ панели к приватному ключу, если он остался от прежних версий.
    if id telemt-panel &>/dev/null && command -v setfacl >/dev/null 2>&1; then
        setfacl -x u:telemt-panel /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null
        [ -n "$DOMAIN_REALITY" ] && \
            setfacl -R -x u:telemt-panel "/etc/letsencrypt/archive/${DOMAIN_REALITY}" 2>/dev/null
        echo -e "${GREEN}✓ Доступ панели к сертификату отозван.${NC}"
    fi

    read -p "$(echo -e "${YELLOW}Удалить также сохранённые учётные данные и конфиг стека? [y/N]: ${NC}")" del_conf
    if [[ "$del_conf" =~ ^[Yy]$ ]]; then
        rm -f "$STACK_CONF" "$STACK_CREDS"
        echo -e "${GREEN}✓ Конфиг и учётные данные удалены.${NC}"
    else
        echo -e "${YELLOW}! Конфиг сохранён: $STACK_CONF${NC}"
    fi

    echo -e "\n${GREEN}✅ Стек telemt удалён.${NC}"
    read -p "Нажмите Enter..."
}

# ----------------------------------------------------------------------
# ГЛАВНОЕ МЕНЮ
# ----------------------------------------------------------------------
function run_telemt_menu {
    while true; do
        clear 2>/dev/null
        load_stack_conf
        ui_title "🛫  СТЕК TELEMT / MTPROTO"
        echo ""
        local tp_url; tp_url=$(telemt_panel_url)
        echo -e "   ${C_NAME}$(ui_pad '✈  telemt' 20)${NC}$(stack_status_line)"
        echo -e "   ${C_NAME}$(ui_pad '🖥  telemt_panel' 20)${NC}$(panel_status_line)"
        [ -n "$tp_url" ] && ui_kv '🌐  Адрес панели' "$tp_url" 20
        # Учётки telemt_panel печатаются здесь, а не в главном меню: то
        # открывается при каждом входе по SSH, и его скриншот лежит в публичном
        # README. printf, а не echo -e: пароль приходит аргументом и не
        # разбирается на escape-последовательности. Значения жирным, а не
        # цветом: серый и жёлтый на светлом терминале одинаково плохо читаются,
        # а это ровно та строка, ради которой сюда и заходят.
        if [ -n "$PANEL_ADMIN_USER" ] || [ -n "$PANEL_ADMIN_PASS" ]; then
            printf "   %b%s%b%b%s%b\n" "$C_NAME" "$(ui_pad '👤  Логин' 20)" "$NC" \
                "$C_SECRET" "$(_secret_clean "$PANEL_ADMIN_USER")" "$NC"
            printf "   %b%s%b%b%s%b\n" "$C_NAME" "$(ui_pad '🔑  Пароль' 20)" "$NC" \
                "$C_SECRET" "$(_secret_clean "$PANEL_ADMIN_PASS")" "$NC"
        fi
        echo -e "   ${C_NAME}$(ui_pad '🎭  Маскировка' 20)${NC}$(mask_status_line)"
        echo -e "   ${C_NAME}$(ui_pad '🔒  MTProxyL' 20)${NC}$(mtproxyl_status_line)"
        if mtproxyl_is_installed; then
            ui_kv '⌨  Его менеджер' 'команда mtproxyl из любой точки системы' 20
        fi
        # Раньше домены печатались через слэш, и по строке было не понять, какой
        # из них за что отвечает. Формулировки те же, что в ask_domains, чтобы
        # назначение домена описывалось везде одинаково.
        if [ -n "$DOMAIN_PANEL" ]; then
            # Домены вводит человек, а печатаются они при каждой отрисовке —
            # чистим от управляющих символов, как и остальные адреса.
            local dp dr
            dp=$(_addr_clean "$DOMAIN_PANEL"); dr=$(_addr_clean "$DOMAIN_REALITY")
            echo ""
            ui_section "ДОМЕНЫ"
            echo -e "   🎯  ${C_NAME}$(ui_pad "$dp" 34)${NC}${C_DESC}панель 3x-ui, она же цель self-SNI${NC}"
            echo -e "   🛡  ${C_NAME}$(ui_pad "$dr" 34)${NC}${C_DESC}SNI-роутинг REALITY${NC}"
        fi
        echo ""
        ui_section "УСТАНОВКА"
        ui_danger_item "1" "Установить весь стек" "СТИРАЕТ существующую 3x-ui"
        ui_item "2" "➕" "Добавить telemt"     "К уже работающей 3x-ui-pro"
        echo ""
        ui_section "ЭКСПЛУАТАЦИЯ"
        ui_item "3" "🩺" "Диагностика"        "Состояние стека и проверка маскировки"
        ui_item "4" "🔧" "Восстановить nginx"  "Маска и доступ к панели заново"
        ui_item "5" "🔬" "Сверить TLS"         "Отпечатки маски и панели, PQ"
        ui_item "6" "🔑" "Учётные данные"      "Логин и пароль telemt_panel"
        ui_item "7" "🚥" "Управление службами" "Старт, стоп, журналы"
        echo ""
        ui_section "ДОПОЛНИТЕЛЬНО"
        ui_item "8" "🔒" "MTProxyL"            "Лимитер, обход, тонкая настройка"
        ui_item "9" "🧱" "Пересборка nginx"    "OpenSSL 3.5 и постквантовый TLS"
        echo ""
        ui_danger_item "10" "Удалить стек telemt" "telemt, панель, маска, конфиги"
        ui_item "X" "🔙" "Назад"
        echo ""

        read -p "Ваш выбор [1-10, X]: " choice
        case $choice in
            1) run_install full ;;
            2) run_install addon ;;
            3) run_diagnostics ;;
            4) restore_mask ;;
            5) check_tls_parity ;;
            6) show_credentials ;;
            7) manage_services ;;
            8) run_mtproxyl ;;
            9) run_rebuild_nginx ;;
            10) uninstall_stack ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

run_telemt_menu
