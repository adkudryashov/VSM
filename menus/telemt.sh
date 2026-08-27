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

# Установка telemt_panel. Та же, что зовёт установщик стека, — пункт
# «Веб-панель» ставит панель ровно тем же кодом, а не своей копией.
if [ -f "$VSM_LIB/panel_install.sh" ]; then
    # shellcheck disable=SC1091
    source "$VSM_LIB/panel_install.sh"
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

# Записать значение в /etc/vsm/telemt.conf: заменить, если ключ уже есть,
# дописать, если нет.
#
# Раньше значения только ДОПИСЫВАЛИСЬ (printf ... >> "$STACK_CONF"). Пока это
# делалось один раз на установку, дублей не возникало. Но панель теперь можно
# поставить, снять и поставить снова из меню, и каждый круг оставлял бы вторую
# строку PANEL_PREFIX. Читается конфиг через source, то есть побеждает
# последняя строка — работать это будет, но файл, где ключ встречается трижды с
# разными значениями, невозможно читать глазами, а именно глазами его читают,
# когда что-то пошло не так.
#
# Пишем во временный файл рядом и переименовываем: обрыв на середине не должен
# оставить конфиг стека полупустым. Права 600 — внутри пароль панели.
function _stack_conf_set {
    local key="$1" value="$2" tmp
    [ -n "$key" ] || return 1
    tmp="$(mktemp "${STACK_CONF}.XXXXXX")" || return 1
    if [ -f "$STACK_CONF" ]; then
        grep -v "^${key}=" "$STACK_CONF" > "$tmp" 2>/dev/null || true
    fi
    # %q — значение переживает повторный source без риска инъекции.
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STACK_CONF"
}

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
    if ! have_cmd telemt && [ ! -f /etc/telemt/telemt.toml ]; then
        echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"
    elif systemctl is-active --quiet telemt; then
        echo -e "${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e "${YELLOW}ОСТАНОВЛЕН${NC}"
    fi
}

# Строка веб-панели в шапке: ИМЯ той, что стоит, и её состояние.
#
# Прежде здесь безусловно печаталось «telemt_panel  НЕ УСТАНОВЛЕН», а адрес
# MTProxyL-Panel показывался ниже без имени. На установке с MTProxyL шапка
# читалась так: панели нет, но адрес почему-то есть. Владелец на это и указал.
#
# Само имя теперь считает panel_installed_name из lib/panels.sh: тот же вопрос
# задаёт и главное меню, а два ответа на один вопрос рано или поздно
# расходятся.
function panel_name_line {
    panel_installed_name
}

function panel_any_status_line {
    if panel_telemt_installed; then
        if systemctl is-active --quiet telemt-panel; then
            echo -e "${GREEN}РАБОТАЕТ${NC}"
        else
            echo -e "${YELLOW}ОСТАНОВЛЕНА${NC}"
        fi
    elif panel_mtproxyl_installed; then
        if systemctl is-active --quiet mtproxyl-panel; then
            echo -e "${GREEN}РАБОТАЕТ${NC}"
        else
            echo -e "${YELLOW}ОСТАНОВЛЕНА${NC}"
        fi
    else
        echo -e "${RED}НЕ УСТАНОВЛЕНА${NC}"
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

    # Ставить ли telemt_panel.
    #
    # Раньше она приезжала молча, четвёртым этапом, и отказаться было негде. А
    # панелей две: тот, кто собирается ставить MTProxyL-Panel, получал сначала
    # установку telemt_panel, а через двадцать минут её удаление стражем
    # исключительности — с заведением системного пользователя, пятнадцати строк
    # NOPASSWD и секретного префикса в nginx по дороге. Каждый такой круг
    # «поставить и снести» — лишний шанс оставить за собой права root у
    # несуществующей службы; именно так однажды и остался
    # /etc/sudoers.d/telemt-panel.
    #
    # Умолчание — ставить: без панели telemt полностью работоспособен, но
    # человек, пришедший по README, ждёт веб-интерфейс.
    echo -e "\n${CYAN}Веб-панель управления telemt.${NC}"
    echo -e "${C_DESC}   Их две, на сервере может быть только одна. Вторую — MTProxyL-Panel —"
    echo -e "   ставит команда mtproxyl, и она появится позже. Любую из двух можно"
    echo -e "   поставить или сменить потом пунктом «Веб-панель».${NC}"
    local want_panel
    read -p "Поставить telemt_panel сейчас? [Y/n]: " want_panel
    case "$want_panel" in
        [Nn]*) INSTALL_PANEL=0
               echo -e "${BLUE}   Панель не ставится. telemt и маскировка работают без неё.${NC}" ;;
        *)     INSTALL_PANEL=1 ;;
    esac

    echo -e "\n${YELLOW}Запускаю установку. Это займёт несколько минут.${NC}\n"
    sleep 1

    DOMAIN_PANEL="$ASK_PANEL" \
    DOMAIN_REALITY="$ASK_REALITY" \
    TELEMT_PORT="${p_telemt:-${TELEMT_PORT:-8444}}" \
    INSTALL_PANEL="$INSTALL_PANEL" \
    PANEL_PORT="${p_panel:-${PANEL_PORT:-9444}}" \
        bash "$STACK_SCRIPT" --mode "$mode"

    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# ======================================================================
# ВЕБ-ПАНЕЛЬ: ВЫБРАТЬ, ПОСТАВИТЬ, СНЯТЬ
#
# Панелей две, и они взаимоисключающие. До этого пункта выбора не было вовсе:
# telemt_panel приезжала сама этапом 4 установки всего стека, MTProxyL-Panel
# ставилась чужой командой мимо VSM, а снятая telemt_panel не возвращалась
# ничем, кроме переустановки стека — то есть стирания 3x-ui вместе с базой,
# инбаундами и всеми пользователями.
#
# Здесь всё в одном месте: что стоит сейчас, поставить любую из двух,
# переключиться с одной на другую, снять совсем.
# ======================================================================

# Какая реализация sudo в системе.
#
# Ubuntu 26.04 ставит по умолчанию sudo-rs, и его visudo НЕ принимает символ *
# в аргументах команд. Установщик MTProxyL-Panel генерирует семь таких правил
# (journalctl -u telemt -n * и подобные), visudo отвергает файл целиком, и
# установка обрывается на середине: бинарь и конфиг записаны, юнита и прав нет.
# Поймано на приёмке 27.08.2026.
#
# Печатает rs, classic или пустую строку, если понять не удалось.
function _sudo_flavor {
    command -v sudo >/dev/null 2>&1 || return 0
    if sudo --version 2>&1 | head -1 | grep -qi "sudo-rs"; then
        echo "rs"
    else
        echo "classic"
    fi
}

# Предупредить про sudo-rs ДО запуска чужого установщика.
#
# Спрашиваем, а не переключаем молча: подмена системного sudo — решение
# владельца, а не побочный эффект установки панели. Возвращает 0, если можно
# продолжать.
function _panel_warn_sudo_rs {
    [ "$(_sudo_flavor)" = "rs" ] || return 0

    echo
    echo -e "${YELLOW}❗  В системе sudo-rs — установщик панели на нём упадёт.${NC}"
    echo -e "${BLUE}   Ubuntu 26.04 ставит sudo-rs вместо классического sudo, а его visudo"
    echo -e "   не принимает символ * в аргументах команд. Установщик MTProxyL-Panel"
    echo -e "   генерирует семь таких правил, и файл отвергается целиком."
    echo -e "   Установка оборвётся на середине: бинарь ляжет, службы не будет.${NC}"
    echo
    echo -e "${BLUE}   Обойти можно только переключением системы на классический sudo."
    echo -e "   Он уже установлен: /usr/bin/sudo.ws. Переключение обратимо"
    echo -e "   (update-alternatives --auto sudo) и переживает обновления пакетов.${NC}"
    echo
    echo -e "${YELLOW}   Чем это грозит:${NC}${BLUE} панель получит право подменять /bin/telemt"
    echo -e "   и перезапускать его. Если sudo когда-нибудь вернётся на sudo-rs,"
    echo -e "   правила панели перестанут работать — она откроется, но её кнопки"
    echo -e "   станут пустыми. Сверка с реестром об этом скажет.${NC}"
    echo
    local answer
    read -r -p "$(echo -e "${YELLOW}Переключить sudo на классический и продолжить? [y/N]: ${NC}")" answer
    case "$answer" in
        [Yy]*) ;;
        *) echo -e "${BLUE}Отменено. sudo не тронут, панель не ставится.${NC}"; return 1 ;;
    esac

    if [ ! -x /usr/bin/sudo.ws ]; then
        echo -e "${RED}❌ /usr/bin/sudo.ws не найден — переключать не на что.${NC}"
        echo -e "${YELLOW}   Поставьте пакет классического sudo и повторите.${NC}"
        return 1
    fi
    if ! update-alternatives --set sudo /usr/bin/sudo.ws >/dev/null 2>&1; then
        echo -e "${RED}❌ update-alternatives не переключил sudo.${NC}"
        return 1
    fi
    # Проверяем фактом, а не кодом возврата предыдущего шага.
    if [ "$(_sudo_flavor)" = "classic" ]; then
        echo -e "${GREEN}  ✓ sudo переключён на классический${NC}"
        return 0
    fi
    echo -e "${RED}❌ sudo всё ещё sudo-rs — установку не начинаю.${NC}"
    return 1
}

# Установка telemt_panel из меню.
#
# Параметры берём из /etc/vsm/telemt.conf, недостающие заводим и дописываем туда
# же — ровно как это делает установщик стека. Пароль не спрашиваем: генерируем и
# показываем пунктом «Учётные данные». Один способ завести панель — один способ
# узнать её пароль.
function _panel_do_install_telemt {
    if [ -z "$DOMAIN_PANEL" ]; then
        echo -e "${RED}❌ Стек telemt не настроен — нет домена панели.${NC}"
        echo -e "${YELLOW}   Панель подключается к 443 домена панели; без него её некуда вести.${NC}"
        return 1
    fi
    panel_ensure_exclusive telemt || return 1

    PANEL_PORT="${PANEL_PORT:-9444}"
    PANEL_ADMIN_USER="${PANEL_ADMIN_USER:-admin}"
    [ -n "$PANEL_ADMIN_PASS" ] || PANEL_ADMIN_PASS="$(openssl rand -base64 20)"
    [ -n "$PANEL_PREFIX" ]     || PANEL_PREFIX="$(panel_proxy_gen_prefix)"

    panel_install_telemt "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS" "$PANEL_PORT" \
                         "$DOMAIN_PANEL" "$DOMAIN_REALITY" "$PANEL_PREFIX" || return 1

    # Состояние пишем ТОЛЬКО после успеха: адрес и пароль несуществующей панели
    # в конфиге — тот же дефект, что чинили на экране доступов.
    _stack_conf_set PANEL_PORT       "$PANEL_PORT"
    _stack_conf_set PANEL_PREFIX     "$PANEL_PREFIX"
    _stack_conf_set PANEL_ADMIN_USER "$PANEL_ADMIN_USER"
    _stack_conf_set PANEL_ADMIN_PASS "$PANEL_ADMIN_PASS"
    echo -e "${GREEN}✓ telemt_panel установлена. Адрес и пароль — пункт «Учётные данные».${NC}"
    return 0
}

# Установка MTProxyL-Panel из меню.
#
# Ставит её ЕЁ ЖЕ команда: чужой установщик знает про свои каталоги, службы и
# правила больше, чем мы, и останется верным после своих же обновлений. Наше
# дело — страж исключительности и предупреждение про sudo-rs до, а секретный
# путь после.
function _panel_do_install_mtproxyl {
    if ! command -v mtproxyl >/dev/null 2>&1; then
        echo -e "${RED}❌ MTProxyL не установлен — его панель ставится его же командой.${NC}"
        echo -e "${YELLOW}   Сначала пункт «MTProxyL» этого меню.${NC}"
        return 1
    fi
    _panel_warn_sudo_rs || return 1
    panel_ensure_exclusive mtproxyl || return 1

    echo -e "${CYAN}>>> Запускаю mtproxyl panel install...${NC}"
    mtproxyl panel install

    # Проверяем фактом: чужой установщик мог оборваться на середине и сказать об
    # этом только своим текстом, а код возврата у него не всегда говорящий.
    if ! panel_mtproxyl_installed; then
        echo -e "${RED}❌ Панель не установилась — службы mtproxyl-panel нет.${NC}"
        echo -e "${YELLOW}   Причина напечатана выше её установщиком.${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ MTProxyL-Panel установлена.${NC}"
    echo -e "${YELLOW}   Секретный путь ей ещё не выдан — снаружи она недоступна."
    echo -e "   Выдайте пунктом «Восстановить nginx» этого меню.${NC}"
    return 0
}

# Снять панель совсем.
function _panel_do_remove {
    local what name answer
    if panel_telemt_present; then
        what=telemt
    elif panel_mtproxyl_present; then
        what=mtproxyl
    else
        echo -e "${BLUE}Панели нет — снимать нечего.${NC}"
        return 0
    fi
    name="$(panel_human_name "$what")"

    echo
    echo -e "${RED}❗  Будет удалена ${name}.${NC}"
    echo -e "${YELLOW}   Уйдут её учётные данные, секретный префикс в nginx и настройки."
    echo -e "   Сам telemt и маскировка продолжат работать: панель им не нужна.${NC}"
    echo -e "${BLUE}   Резервная копия секретов снимается перед удалением.${NC}"
    echo
    read -r -p "$(echo -e "${RED}Введите БОЛЬШИМИ буквами ДА, чтобы удалить ${name}: ${NC}")" answer
    if [ "$answer" != "ДА" ]; then
        echo -e "${BLUE}Отменено.${NC}"
        return 1
    fi

    local backup="${VSM_ROOT:-/root/VSM}/tools/vsm-backup.sh"
    [ -x "$backup" ] && bash "$backup" >/dev/null 2>&1 \
        && echo -e "${GREEN}  ✓ резервная копия снята${NC}"

    "panel_remove_${what}"
    if "panel_${what}_present"; then
        echo -e "${RED}❌ ${name} удалить не удалось — уберите вручную.${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ ${name} удалена.${NC}"
    return 0
}

# Сменить секретный путь панели.
#
# Путь — это пароль от входа: знающий его видит форму входа в админку. Утечь он
# может как угодно — скриншотом, журналом сеанса, пересланным выводом, — и
# сменить его до сих пор было НЕЧЕМ. mtpl_panel_set_prefix звали только когда
# пути нет вовсе, а у telemt_panel префикс писался один раз при установке.
# Единственным способом отреагировать на утечку оставалась переустановка
# панели.
#
# Меняем и в панели, и в nginx, и проверяем фактом, что новый адрес отвечает.
# Новый путь на экран НЕ печатаем — за ним идут в «Учётные данные».
function _panel_do_rotate_prefix {
    local new pv code port
    if [ -z "$DOMAIN_PANEL" ]; then
        echo -e "${RED}❌ Нет домена панели — путь некуда прикладывать.${NC}"
        return 1
    fi
    if ! panel_telemt_installed && ! panel_mtproxyl_installed; then
        echo -e "${BLUE}Панели нет — менять нечего.${NC}"
        return 0
    fi
    pv="$(nginx_mask_panel_vhost "$DOMAIN_PANEL")" || {
        echo -e "${RED}❌ Не найден vhost домена ${DOMAIN_PANEL}.${NC}"
        return 1
    }
    new="$(panel_proxy_gen_prefix)"

    echo -e "${YELLOW}   Прежний адрес перестанет работать сразу.${NC}"

    if panel_mtproxyl_installed; then
        port="$(mtpl_panel_port)"
        # set_prefix сам проверяет живую панель и откатывается, если она не
        # отдаёт новый путь: конфиг и nginx не должны разъехаться ни на миг.
        if ! mtpl_panel_set_prefix "$new" >/dev/null; then
            echo -e "${RED}❌ Панель не приняла новый путь — ничего не менялось.${NC}"
            return 1
        fi
        mtpl_proxy_apply "$pv" "$new" "$port" || {
            echo -e "${RED}❌ nginx не принял новый блок (причина выше).${NC}"
            return 1
        }
    else
        port="${PANEL_PORT:-9444}"
        panel_proxy_apply "$pv" "$new" "$port" || {
            echo -e "${RED}❌ nginx не принял новый блок (причина выше).${NC}"
            return 1
        }
        _stack_conf_set PANEL_PREFIX "$new"
    fi

    if code="$(panel_proxy_verify "$DOMAIN_PANEL" "$new")"; then
        echo -e "${GREEN}✓ Путь сменён, панель отвечает ($code).${NC}"
        echo -e "${BLUE}   Новый адрес — пункт «Учётные данные».${NC}"
        return 0
    fi
    echo -e "${RED}❌ По новому адресу панель вернула $code.${NC}"
    echo -e "${YELLOW}   Повторите пункт «Восстановить nginx».${NC}"
    return 1
}

function run_panel_menu {
    local choice url left
    while true; do
        load_stack_conf
        clear 2>/dev/null
        ui_title "🖥  ВЕБ-ПАНЕЛЬ"
        echo ""
        ui_section "СЕЙЧАС"

        if panel_telemt_installed || panel_mtproxyl_installed; then
            ui_kv "🖥  Установлена" "$(panel_installed_name)" 18
            echo -e "   ${C_NAME}$(ui_pad "🚥  Состояние" 18)${NC}$(panel_any_status_line)"
            if panel_telemt_installed; then
                url="$(telemt_panel_url 2>/dev/null)"
            else
                url="$(mtpl_panel_url 2>/dev/null)"
            fi
            if [ -n "$url" ]; then
                ui_kv "🌐  Адрес" "$url" 18
            else
                echo -e "   ${C_NAME}$(ui_pad "🌐  Адрес" 18)${NC}${C_WARN}пути нет — пункт «Восстановить nginx»${NC}"
            fi
        elif panel_telemt_leftovers || panel_mtproxyl_leftovers; then
            # Файлы без юнита. Молчать нельзя: они занимают те же пути, и
            # следующая установка о них споткнётся.
            left=telemt
            panel_mtproxyl_leftovers && left=mtproxyl
            ui_kv "⚠  Состояние" "следы неудачной установки $(panel_human_name "$left")" 18
            # Страж исключительности убирает следы ЧУЖОЙ панели. Следы той же
            # самой он не трогает, и обещать обратное нельзя: на приёмке
            # 27.08.2026 экран сказал «уберутся сами», а выручил чужой
            # установщик, не VSM.
            ui_kv "➡  Что делать" "снять панель совсем — уберёт следы" 18
        else
            ui_kv "🖥  Установлена" "ни одной" 18
            ui_kv "➡  Без панели" "telemt и маскировка работают полностью" 18
        fi

        echo ""
        ui_section "ВЫБОР"
        ui_item "1" "🏠" "telemt_panel"   "Своя: ставит и настраивает VSM"
        ui_item "2" "🧩" "MTProxyL-Panel" "Чужая: ставит команда mtproxyl"
        echo ""
        ui_section "ОБСЛУЖИВАНИЕ"
        ui_item "3" "🔀" "Сменить путь"   "Если секретный адрес засветился"
        echo ""
        ui_danger_item "4" "Снять панель совсем" "telemt при этом не трогается"
        ui_item "X" "🔙" "Назад"
        echo ""
        echo -e "${C_DESC}   На сервере может быть только одна: две админки — вдвое больше"
        echo -e "   того, что можно взломать и надо обновлять, ради одной задачи.${NC}"
        echo ""

        read -p "Ваш выбор [1-4, X]: " choice || return
        case "$choice" in
            1) _panel_do_install_telemt;   read -p "Нажмите Enter..." ;;
            2) _panel_do_install_mtproxyl; read -p "Нажмите Enter..." ;;
            3) _panel_do_rotate_prefix;    read -p "Нажмите Enter..." ;;
            4) _panel_do_remove;           read -p "Нажмите Enter..." ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
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
    # Та же правка, что и в шапке: диагностика обязана называть панель, которая
    # СТОИТ, а не ту, которой нет. Порт берём у неё же — у двух панелей он
    # разный (9444 и 8080), и печатать чужой значит отправлять человека
    # проверять пустой порт.
    if panel_mtproxyl_installed; then
        _diag_panel_port="$(mtpl_panel_port 2>/dev/null)"
        echo -e "$(printf '%-15s' "$(panel_name_line):") [$(panel_any_status_line)]  порт ${_diag_panel_port:-8080}"
    else
        echo -e "$(printf '%-15s' "$(panel_name_line):") [$(panel_any_status_line)]  порт ${PANEL_PORT}"
    fi
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
    # telemt_panel на сервере может отсутствовать вовсе: VSM держит одну панель
    # из двух, и на установке с MTProxyL-Panel её нет.
    #
    # Поймано прогоном установки MTProxyL-Panel на стенде. Прежняя версия этого
    # не смотрела и на пустом месте делала три вещи подряд: генерировала
    # префикс и дописывала его в конфиг, вписывала в vhost блок, проксирующий
    # на никем не занятый порт 9444, и объявляла отказ на совершенно исправной
    # системе. Худшее из трёх — блок: секретный адрес начинал что-то отвечать
    # там, где до этого не было ничего.
    if ! panel_telemt_installed; then
        echo -e "\n${C_DESC:-}>>> telemt_panel не установлена — восстанавливать нечего.${NC}"
        # Блок мог остаться от прежней установки. Снимаем молча и проверяем
        # фактом: та же функция, что и при удалении панели.
        _panel_strip_nginx panel_proxy_remove "$PANEL_PROXY_BEGIN"
        # Не «всё плохо», а «нечего делать»: иначе итоговая строка ругалась бы
        # на исправной установке при каждом восстановлении маски.
        proxy_ok=1
        mtpl_restore_proxy
        [ "$mask_ok" = 1 ] || \
            echo -e "\n${YELLOW}Не всё восстановлено — прогони «Статус и диагностика».${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo -e "\n${CYAN}>>> Восстановление доступа к telemt_panel...${NC}"
    if [ -z "$PANEL_PREFIX" ]; then
        # Конфиг от прежней версии, где панель висела на 0.0.0.0:9444. Префикс
        # генерируем сейчас и дописываем в конфиг — это и есть переезд.
        PANEL_PREFIX="$(panel_proxy_gen_prefix)"
        _stack_conf_set PANEL_PREFIX "$PANEL_PREFIX"
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
            # Адрес не печатаем: секретный путь это и есть пароль от входа, а
            # вывод этого пункта попадает в журналы сеанса и в скриншоты.
            echo -e "${GREEN}✅ Панель отвечает ($code) по своему секретному пути.${NC}"
            echo -e "${BLUE}   Адрес — пункт «Учётные данные».${NC}"
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

    if [ -z "$port" ]; then
        echo -e "${YELLOW}   В ${MTPL_PANEL_CONF} не задан listen — отдавать нечего.${NC}"
        echo -e "${YELLOW}   Настройте панель и повторите.${NC}"
        return 0
    fi
    # Установщик автора base_path не пишет — панель работает от корня, и
    # спрятать её за префикс в таком виде нельзя. Раньше ключ дописывали
    # руками: единственный шаг установки, который нигде не описан и потому
    # забывается. Теперь этот пункт настраивает панель впервые ровно так же,
    # как он это давно делает для telemt_panel.
    if [ -z "$prefix" ]; then
        echo -e "${YELLOW}   У панели нет секретного пути — создаю (это первичная настройка).${NC}"
        if ! prefix="$(mtpl_panel_set_prefix "$(panel_proxy_gen_prefix)")"; then
            echo -e "${RED}❌ Не удалось задать секретный путь (причина выше).${NC}"
            return 0
        fi
        echo -e "${GREEN}   ✓ секретный путь задан, панель перезапущена${NC}"
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
            # Адрес НЕ печатаем.
            #
            # Секретный путь — это и есть пароль от входа: знающий его видит
            # форму входа в админку. Этот пункт запускают в обычном терминале,
            # его вывод попадает в журналы сеанса, в скриншоты и в переписку.
            # Проверено на приёмке 27.08.2026: путь утёк именно так, из вывода
            # этого пункта, — и это третий случай за проект. Вывод сверки
            # маскируется с 15.08.2026, а тут маскировки не было.
            #
            # Место для секретов одно — «Учётные данные», и туда заходят
            # осознанно.
            echo -e "${GREEN}✅ MTProxyL-Panel отвечает ($code) по своему секретному пути.${NC}"
            echo -e "${BLUE}   Адрес — пункт «Учётные данные».${NC}"
        else
            echo -e "${RED}❌ Блок применён, но панель по адресу вернула $code.${NC}"
            echo -e "${YELLOW}   Сверьте base_path в ${MTPL_PANEL_CONF} с блоком в ${pv}.${NC}"
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
        # Строки про telemt_panel печатаем ТОЛЬКО пока она есть.
        #
        # Файл пишется один раз при установке стека и с тех пор не меняется. А
        # панель на сервере — сменная: страж сносит её перед установкой
        # MTProxyL-Panel. После этого экран продолжал показывать её адрес,
        # логин и пароль — данные, которые выглядят рабочими, никуда не
        # подходят и уводят разбираться не туда. Ровно то же самое мы уже
        # чинили в шапке стека; здесь оно осталось незамеченным, потому что
        # чинили по симптому, а не по причине.
        local tp_here=0; panel_telemt_installed && tp_here=1
        # "|| [ -n "$line" ]" — чтобы не потерять последнюю строку файла, если
        # он остался без завершающего перевода строки после правки руками.
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "Панель 3x-ui-pro:"*)
                    [ -n "$live_url" ] && line="Панель 3x-ui-pro:   $live_url" ;;
                "telemt_panel"*)
                    [ "$tp_here" -eq 1 ] || continue ;;
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

        # MTProxyL-Panel — живьём, а не из файла.
        #
        # В файле её нет и быть не может: он написан установщиком стека, а
        # панель ставят позже и отдельной командой. Секретный путь к тому же
        # меняется — значит единственный верный источник это её собственный
        # конфиг, и читать надо при каждой отрисовке.
        #
        # Пароль не показываем и не ищем: панель хранит только его хэш.
        # Промолчать об этом было бы хуже, чем сказать прямо, — человек решил
        # бы, что VSM пароль потерял, и пошёл бы искать его по файлам.
        if panel_mtproxyl_installed; then
            local mp_url mp_user
            mp_url="$(mtpl_panel_url 2>/dev/null)"
            mp_user="$(mtpl_panel_user 2>/dev/null)"
            echo ""
            # Подписи выравниваем по той же колонке 20, что и строки из файла:
            # там отступ записан прямо в тексте, здесь его ставит ui_pad. Иначе
            # блок панели висит ступенькой посреди ровного экрана.
            #
            # Панель названа один раз, в подписи адреса. Дальше просто «Логин»
            # и «Пароль»: длинное «MTProxyL-Panel логин» в колонку не влезает,
            # а имя и так стоит строкой выше — тот же приём, что в шапке.
            if [ -n "$mp_url" ]; then
                printf '   %b%s%b%b%s%b\n' "$C_NAME" "$(ui_pad 'MTProxyL-Panel:' 20)" "$NC" \
                    "$C_SECRET" "$mp_url" "$NC"
            else
                printf '   %b%s%b%s\n' "$C_NAME" "$(ui_pad 'MTProxyL-Panel:' 20)" "$NC" \
                    "путь не выдан — пункт «Восстановить nginx»"
            fi
            [ -n "$mp_user" ] && printf '   %b%s%b%b%s%b\n' \
                "$C_NAME" "$(ui_pad 'Логин:' 20)" "$NC" "$C_SECRET" "$mp_user" "$NC"
            printf '   %b%s%b%s\n' "$C_NAME" "$(ui_pad 'Пароль:' 20)" "$NC" \
                "не хранится, панель держит хэш; сменить: mtproxyl panel password"
        fi

        echo ""
        ui_kv '📄  Файл' "$STACK_CREDS (права 600)" 17
    fi
    read -p "Нажмите Enter..."
}

function manage_services {
    while true; do
        clear 2>/dev/null
        echo -e "${CYAN}--- 🔧  УПРАВЛЕНИЕ СЛУЖБАМИ СТЕКА --------------------${NC}"
        # Управляем службой ТОЙ панели, что стоит. Прежде пункт 2 всегда
        # означал telemt-panel, и на установке с MTProxyL-Panel он открывал
        # управление службой, которой на сервере нет: «неактивна», старт не
        # помогает, причина не названа.
        local _panel_unit _panel_name
        _panel_name="$(panel_name_line)"
        if panel_mtproxyl_installed; then _panel_unit=mtproxyl-panel; else _panel_unit=telemt-panel; fi
        echo -e "    telemt:       [$(stack_status_line)]"
        echo -e "    $(printf '%-13s' "${_panel_name}:") [$(panel_any_status_line)]"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        ui_item "1" "📊" "Служба telemt"        "Статус, старт, стоп, логи"
        ui_item "2" "💻" "Служба ${_panel_name}" "Статус, старт, стоп, логи"
        ui_item "X" "🔙" "Назад"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        read -p "Выбор: " s_choice
        case $s_choice in
            1) manage_service_status_restart telemt ;;
            2) manage_service_status_restart "$_panel_unit" ;;
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
    [ -f "$MTPROXYL_DIR/mtproxyl.sh" ] || have_cmd mtproxyl
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
        manager)    echo -e "${GREEN}УСТАНОВЛЕН${ver:+ v$ver}${NC} ${YELLOW}(Manager — см. пункт «MTProxyL»)${NC}" ;;
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
    # управляет self-SNI маскировка VSM. «Восстановить nginx» будет возвращать
    # их обратно, и вдвоём они устроят качели.
    echo -e "${RED}❗  Selfmask в его меню — не включайте.${NC}"
    echo -e "${YELLOW}   Маскировку в этой сборке держит VSM («Восстановить nginx»),"
    echo -e "   а Selfmask переставит tls_domain, mask_host и mask_port на свой nginx."
    echo -e "   Постквантовый TLS для маскировки — это «Пересборка nginx», ещё один"
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
    have_cmd mtproxyl && was_installed=1

    if [ "$was_installed" -eq 0 ]; then
        # Страж ДО запуска чужого установщика, а не после.
        #
        # Установщик автора заканчивается exec-ом своего меню, то есть после
        # него управление к нам уже не вернётся — спрашивать будет некому и
        # некогда. Отказ владельца прерывает установку целиком.
        #
        # ЗДЕСЬ БЫЛО НАПИСАНО «Плюс он ставит панель заодно» — И ЭТО НЕВЕРНО.
        # Проверено на приёмке с нуля 23.08.2026: установщик MTProxyL панель
        # НЕ ставит, её поднимают отдельной командой `mtproxyl panel install`.
        # Из-за ошибочной посылки страж сносил telemt_panel и уходил, оставляя
        # сервер вообще без админки, и никто об этом не говорил ни слова.
        # Владелец узнал об этом, наткнувшись на 404 по прежнему адресу.
        #
        # Снести панель до установки всё равно правильно: чужой установщик
        # уходит в свой exec, и второго случая спросить не будет. Но сказать,
        # что панели теперь нет и чем её вернуть, — обязаны. Это ниже.
        panel_ensure_exclusive mtproxyl || { read -p "Нажмите Enter..."; return; }
        echo -e "${CYAN}>>> Устанавливаю MTProxyL...${NC}"
        run_remote_script "https://raw.githubusercontent.com/$MTPROXYL_REPO/main/install.sh"
    else
        echo -e "${GREEN}>>> Запускаю mtproxyl (выход из него вернёт сюда)...${NC}"
        sleep 1
        mtproxyl
    fi

    if have_cmd mtproxyl; then
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

        # Сервер без единой веб-панели — состояние законное, но молчать о нём
        # нельзя.
        #
        # Страж сносит telemt_panel ПЕРЕД установкой MTProxyL, а панель
        # MTProxyL её установщик не ставит (проверено 23.08.2026). Значит с
        # этой минуты админки на сервере нет вовсе. Прежде об этом не
        # сообщалось никак, и владелец узнавал сам — по 404 на прежнем адресе,
        # то есть в тот момент, когда панель понадобилась.
        #
        # Спрашиваем состояние, а не помним его: панель могли поставить и из
        # чужого меню, пока мы ждали возврата.
        if ! panel_telemt_installed && ! panel_mtproxyl_installed; then
            echo -e "\n${YELLOW}❗  Веб-панели на сервере сейчас нет ни одной.${NC}"
            echo -e "${YELLOW}   Установщик MTProxyL свою панель НЕ ставит — она отдельной командой."
            echo -e "   Поставить:  ${CYAN}mtproxyl panel install${YELLOW}   (доступ — вариант 2, только петля)"
            echo -e "   Затем сюда: пункт ${CYAN}4 «Восстановить nginx»${YELLOW} — он выдаст ей секретный"
            echo -e "   путь на 443 и проверит, что она по нему отвечает.${NC}"
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
    echo -e "  $(printf '%-13s' "$(panel_name_line):") $(panel_any_status_line)"

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
        echo -e "   ${C_NAME}$(ui_pad "🖥  $(panel_name_line)" 20)${NC}$(panel_any_status_line)"
        # Адрес и учётки — только у установленной панели.
        #
        # Раньше проверялось наличие значений в конфиге, а не самой панели, и
        # после перехода на MTProxyL-Panel шапка бодро показывала адрес и пароль
        # от снесённой telemt_panel. По этому адресу никто не отвечает, а пароль
        # не подходит никуда — но выглядит это как рабочие данные, и разбираться
        # человек идёт не туда.
        if panel_telemt_installed; then
            [ -n "$tp_url" ] && ui_kv '🌐  Адрес панели' "$tp_url" 20
            # Учётки telemt_panel печатаются здесь, а не в главном меню: то
            # открывается при каждом входе по SSH, и его скриншот лежит в
            # публичном README. printf, а не echo -e: пароль приходит
            # аргументом и не разбирается на escape-последовательности.
            # Значения жирным, а не цветом: серый и жёлтый на светлом терминале
            # одинаково плохо читаются, а это ровно та строка, ради которой
            # сюда и заходят.
            if [ -n "$PANEL_ADMIN_USER" ] || [ -n "$PANEL_ADMIN_PASS" ]; then
                printf "   %b%s%b%b%s%b\n" "$C_NAME" "$(ui_pad '👤  Логин' 20)" "$NC" \
                    "$C_SECRET" "$(_secret_clean "$PANEL_ADMIN_USER")" "$NC"
                printf "   %b%s%b%b%s%b\n" "$C_NAME" "$(ui_pad '🔑  Пароль' 20)" "$NC" \
                    "$C_SECRET" "$(_secret_clean "$PANEL_ADMIN_PASS")" "$NC"
            fi
        fi
        echo -e "   ${C_NAME}$(ui_pad '🎭  Маскировка' 20)${NC}$(mask_status_line)"
        echo -e "   ${C_NAME}$(ui_pad '🔒  MTProxyL' 20)${NC}$(mtproxyl_status_line)"
        # Адрес MTProxyL-Panel показываем ровно там же, где показывали бы адрес
        # своей: панель установлена, но узнать секретный путь к ней было неоткуда
        # — приходилось читать чужой конфиг. Секрет в подменю, а не в главном
        # меню, — то же правило, что и для учёток telemt_panel.
        if panel_mtproxyl_installed; then
            local mp_url; mp_url="$(mtpl_panel_url 2>/dev/null)"
            if [ -n "$mp_url" ]; then
                ui_kv '🌐  Адрес панели' "$mp_url" 20
            else
                # Панель есть, а адреса нет — значит секретный путь ей ещё не
                # выдан. Само по себе это не поломка, но снаружи панель в таком
                # виде недоступна, и молчать об этом нельзя: человек будет
                # искать адрес там, где его никогда не было.
                ui_kv '🌐  Адрес панели' 'нет — выдать: пункт «Восстановить nginx»' 20
            fi
        fi
        # Ни одной панели — состояние законное (страж сносит прежнюю до
        # установки MTProxyL, а её панель ставится отдельной командой), но
        # оставлять человека гадать не надо.
        if ! panel_telemt_installed && ! panel_mtproxyl_installed; then
            ui_kv '🌐  Как поставить' 'пункт «Веб-панель»' 20
        fi
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
        ui_item "3" "🖥" "Веб-панель"          "Выбрать, поставить или снять: их две"
        echo ""
        ui_section "ЭКСПЛУАТАЦИЯ"
        ui_item "4" "🩺" "Диагностика"        "Состояние стека и проверка маскировки"
        ui_item "5" "🔧" "Восстановить nginx"  "Настроить или вернуть маску и доступ"
        ui_item "6" "🔬" "Сверить TLS"         "Отпечатки маски и панели, PQ"
        ui_item "7" "🔑" "Учётные данные"      "Адреса, логины и пароли стека и панели"
        ui_item "8" "🚥" "Управление службами" "Старт, стоп, журналы"
        echo ""
        ui_section "ДОПОЛНИТЕЛЬНО"
        ui_item "9" "🔒" "MTProxyL"            "Лимитер, обход, тонкая настройка"
        ui_item "10" "🧱" "Пересборка nginx"   "OpenSSL 3.5 и постквантовый TLS"
        echo ""
        ui_danger_item "11" "Удалить стек telemt" "telemt, панель, маска, конфиги"
        ui_item "X" "🔙" "Назад"
        echo ""

        read -p "Ваш выбор [1-11, X]: " choice
        case $choice in
            1) run_install full ;;
            2) run_install addon ;;
            3) run_panel_menu ;;
            4) run_diagnostics ;;
            5) restore_mask ;;
            6) check_tls_parity ;;
            7) show_credentials ;;
            8) manage_services ;;
            9) run_mtproxyl ;;
            10) run_rebuild_nginx ;;
            11) uninstall_stack ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

run_telemt_menu
