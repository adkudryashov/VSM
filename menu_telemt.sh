#!/bin/bash
source /usr/local/bin/_config_and_utils.sh

# ----------------------------------------------------------------------
# TELEMT / MTPROTO: УПРАВЛЕНИЕ СТЕКОМ
# 3x-ui-pro + telemt (self-SNI маскировка) + telemt_panel + MEKO
# ----------------------------------------------------------------------

# Каталог репозитория — от расположения скрипта, а не жёстко: при запуске
# через симлинк readlink -f приводит к реальному файлу. Иначе установка
# под прежним именем после обновления не нашла бы свои скрипты.
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STACK_SCRIPT="$REPO_DIR/telemt-stack.sh"
REBUILD_SCRIPT="$REPO_DIR/rebuild-nginx-openssl35.sh"
STACK_CONF="/etc/vsm/telemt.conf"
STACK_CREDS="/etc/vsm/telemt-credentials.txt"

# Генератор self-SNI vhost общий с telemt-stack.sh, он же задаёт MASK_VHOST.
# Раньше это были две копии одного heredoc, и одинаковый дефект приходилось
# бы чинить дважды.
if [ -f "$REPO_DIR/_nginx_mask.sh" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/_nginx_mask.sh"
else
    echo -e "${RED}❌ Не найден $REPO_DIR/_nginx_mask.sh — обнови VSM (install.sh).${NC}"
    exit 1
fi

# Сторонний проект MTproxy-reanimation (лимитер | тюнинг) под Telemt.
# Пришёл на смену MEKO: один самодостаточный файл вместо девяти докачиваемых,
# nftables вместо iptables, бэкап конфигов и откат у каждой функции, а также
# встроенная сверка версий с подтверждением обновления. Лицензия MIT.
MTPR_REPO="Liafanx/MTproxy-reanimation"
MTPR_DIR="/opt/mtproxy-reanimation"

# Прежний MEKO. Нужен только чтобы заметить его следы и предупредить о
# конфликте. У MEKO ДВА режима SYN FIX, и оба ограничивают тот же трафик,
# что и MTproxy-reanimation:
#   iptables — цепочка MTPR_SYNFIX,     юнит mtpr-synfix.service
#   nftables — таблица inet mtpr_synfix, юнит mtpr-nft-synfix.service
MEKO_DIR="/opt/mtpr-simple"
MEKO_NFT_TABLE="mtpr_synfix"
MEKO_UNITS=(mtpr-synfix mtpr-nft-synfix)

function load_stack_conf {
    DOMAIN_PANEL=""; DOMAIN_REALITY=""
    TELEMT_PORT=""; TELEMT_MASK_PORT=""; PANEL_PORT=""
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
    echo -e "  • ${YELLOW}Домен REALITY${NC} — ключ SNI-роутинга, он же адрес telemt_panel"
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

    clear
    echo -e "${CYAN}======================================================${NC}"
    if [ "$mode" == "full" ]; then
        echo -e "${CYAN}     📦  УСТАНОВКА ВСЕГО СТЕКА С НУЛЯ  📦             ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${RED}⚠️  ВНИМАНИЕ: установщик 3x-ui-pro СТИРАЕТ существующую"
        echo -e "    панель — базу, инбаунды и всех пользователей.${NC}"
        if [ -d /etc/x-ui ]; then
            echo -e "${RED}⚠️  На сервере УЖЕ ЕСТЬ установленная 3x-ui (/etc/x-ui).${NC}"
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
    clear
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
        echo -e "${RED}⚠️  Файл маскировки отсутствует!${NC}"
        echo -e "${YELLOW}    Скорее всего его стёрла переустановка или патч 3x-ui-pro."
        echo -e "    Без него telemt при DPI-пробе не отдаёт настоящий сайт."
        echo -e "    Почини пунктом 'Восстановить маскировку'.${NC}"
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
        grep -E '^\[|^mask' /etc/telemt/telemt.toml | sed 's/^/    /'
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

    # Сборка, проверка nginx -t и откат при неудаче — в _nginx_mask.sh,
    # общем с установщиком.
    if nginx_mask_apply "$DOMAIN_PANEL" "$TELEMT_MASK_PORT"; then
        echo -e "${GREEN}✅ Маскировка восстановлена и nginx перезагружен.${NC}"
    else
        echo -e "${RED}❌ Маскировка не восстановлена (причина выше).${NC}"
    fi
    read -p "Нажмите Enter..."
}

function show_credentials {
    clear
    if [ ! -f "$STACK_CREDS" ]; then
        echo -e "${RED}❌ Файл учётных данных не найден ($STACK_CREDS).${NC}"
    else
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}            🔑  УЧЁТНЫЕ ДАННЫЕ СТЕКА  🔑              ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        cat "$STACK_CREDS"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${YELLOW}Файл: $STACK_CREDS (права 600)${NC}"
    fi
    read -p "Нажмите Enter..."
}

function manage_services {
    while true; do
        clear
        echo -e "${CYAN}--- ⚙️  УПРАВЛЕНИЕ СЛУЖБАМИ СТЕКА --------------------${NC}"
        echo -e "    telemt:       [$(stack_status_line)]"
        echo -e "    telemt_panel: [$(panel_status_line)]"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "1) 🎛️   Служба telemt (статус | старт | стоп | логи)"
        echo -e "2) 🖥️   Служба telemt_panel (статус | старт | стоп | логи)"
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
function mtpr_installed_version {
    [ -f "$MTPR_DIR/mtpr.sh" ] || return 1
    grep -m1 -oE '^[[:space:]]*(readonly[[:space:]]+)?VERSION=["'"'"']?[0-9]+(\.[0-9]+)+' \
        "$MTPR_DIR/mtpr.sh" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+'
}

# Версия у автора. Отдельный файл version в репозитории — по нему же
# сверяется и сам mtpr при запуске. Молча пусто, если сети нет.
function mtpr_latest_version {
    curl -fsS --max-time 6 "https://raw.githubusercontent.com/$MTPR_REPO/main/version" 2>/dev/null \
        | tr -d '[:space:]'
}

# Установлен ли MTproxy-reanimation. Смотрим оба признака: каталог автора и
# команду в PATH. Файл есть, а команды нет — установка оборвалась на полпути;
# команда есть, а каталога нет — инструмент поставили в обход нашего пункта.
# В обоих случаях считаем установленным: предлагать поставить то, что уже
# стоит, хуже, чем лишний раз показать «установлен».
function mtpr_is_installed {
    [ -f "$MTPR_DIR/mtpr.sh" ] || command -v mtpr &> /dev/null
}

# Строка состояния для шапки меню. Сеть здесь не трогаем намеренно: шапка
# перерисовывается при каждом возврате в меню, и сверка версии с GitHub
# подвешивала бы её на таймаут всякий раз, когда сети нет.
function mtpr_status_line {
    local ver
    if ! mtpr_is_installed; then
        echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"
        return
    fi
    ver=$(mtpr_installed_version 2>/dev/null)
    echo -e "${GREEN}УСТАНОВЛЕН${ver:+ v$ver}${NC}"
}

# Следы MEKO. Проверяются оба его режима: правила могут остаться и в
# iptables, и в nftables, причём даже без самого менеджера — например, если
# каталог удалили вручную, а служба и таблица уцелели. Именно nftables-вариант
# опаснее: он ограничивает тот же трафик, что и таблица MTproxy-reanimation,
# и внешне это выглядит как необъяснимо заниженный лимит подключений.
function meko_leftovers_warning {
    local found=""
    command -v mekopr &>/dev/null && found="команда mekopr"
    [ -d "$MEKO_DIR" ] && found="${found:+$found, }каталог $MEKO_DIR"
    if iptables-save 2>/dev/null | grep -qiE "meko|synfix"; then
        found="${found:+$found, }цепочка в iptables"
    fi
    if nft list table inet "$MEKO_NFT_TABLE" &>/dev/null; then
        found="${found:+$found, }nft-таблица $MEKO_NFT_TABLE"
    fi
    local u
    for u in "${MEKO_UNITS[@]}"; do
        [ -f "/etc/systemd/system/$u.service" ] && found="${found:+$found, }служба $u"
    done
    [ -z "$found" ] && return 0

    echo -e "${RED}⚠️  На сервере найдены следы MEKO ($found).${NC}"
    echo -e "${YELLOW}   MEKO ставит SYN FIX либо в iptables, либо в nftables — в обоих"
    echo -e "   случаях он ограничивает тот же трафик, что и MTproxy-reanimation."
    echo -e "   Сначала снимите его: ${CYAN}mekopr${YELLOW} → «Удалить SYN FIX»,"
    echo -e "   затем «Удалить MEKO Manager».${NC}\n"
    return 1
}

function run_mtpr {
    clear
    load_stack_conf
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}   🛡️  MTPROXY-REANIMATION — SYN-ЛИМИТЕР И ТЮНИНГ  🛡️  ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    # Пункты чужого меню здесь намеренно не перечисляются: они зависят от
    # состояния сервера и меняются с обновлениями. Любая шпаргалка устареет.
    echo -e "${YELLOW}Сторонний интерактивный менеджер под Telemt: SYN-лимитер на"
    echo -e "nftables, тюнинг sysctl, фиксы для iOS. Он покажет своё меню.${NC}\n"

    local inst latest
    inst=$(mtpr_installed_version)
    latest=$(mtpr_latest_version)
    echo -e "${GREEN}Версии:${NC}"
    echo -e "  установлена:      ${CYAN}${inst:-не установлен}${NC}"
    echo -e "  доступна:         ${CYAN}${latest:-не удалось проверить}${NC}"
    if [ -n "$inst" ] && [ -n "$latest" ] && [ "$inst" != "$latest" ]; then
        echo -e "  ${YELLOW}↑ Есть обновление. mtpr предложит его при запуске.${NC}"
    fi
    echo -e "  порт telemt:      ${CYAN}${TELEMT_PORT:-8444}${NC}\n"

    echo -e "${YELLOW}Код скачивается с GitHub автора и выполняется от root."
    echo -e "Репозиторий не наш (лицензия MIT), содержимое может меняться.${NC}\n"

    meko_leftovers_warning

    if command -v docker &> /dev/null; then
        echo -e "${YELLOW}⚠️  Обнаружен Docker. После применения правил проверьте"
        echo -e "    порядок цепочек: ${CYAN}nft list ruleset${YELLOW} — правило должно"
        echo -e "    отрабатывать раньше цепочек Docker.${NC}\n"
    fi

    echo -e "${BLUE}------------------------------------------------------${NC}"
    # Вопрос зависит от состояния: при установленном инструменте пункт его НЕ
    # переустанавливает, а просто открывает. Прежняя формулировка «Установить и
    # запустить» этого не показывала, и выглядело так, будто установка идёт по
    # кругу.
    if mtpr_is_installed; then
        read -p "$(echo -e "${CYAN}Открыть менеджер mtpr? [y/N]: ${NC}")" go
    else
        read -p "$(echo -e "${CYAN}Установить и запустить MTproxy-reanimation? [y/N]: ${NC}")" go
    fi
    if [[ ! "$go" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Отменено.${NC}"; sleep 1; return
    fi

    # Установщик автора заканчивается exec-ом самого mtpr, то есть меню
    # открывается уже в ходе установки. Поэтому запускаем инструмент сами
    # только когда он был установлен ЗАРАНЕЕ — иначе показали бы его дважды.
    local was_installed=0
    command -v mtpr &> /dev/null && was_installed=1

    if [ "$was_installed" -eq 0 ]; then
        echo -e "${CYAN}>>> Устанавливаю MTproxy-reanimation...${NC}"
        run_remote_script "https://raw.githubusercontent.com/$MTPR_REPO/main/install.sh"
    else
        echo -e "${GREEN}>>> Запускаю mtpr (выход из него вернёт сюда)...${NC}"
        sleep 1
        mtpr
    fi

    if command -v mtpr &> /dev/null; then
        # Проверка нужна и после установки: если автор уберёт exec из своего
        # установщика, инструмент поставится, но не откроется — и без этой
        # подсказки было бы непонятно, произошло ли вообще что-нибудь.
        [ "$was_installed" -eq 0 ] && \
            echo -e "${GREEN}✅ Установлено. Открыть менеджер снова — этот же пункт меню.${NC}"
    else
        echo -e "${RED}❌ Команда mtpr не появилась — установка не удалась.${NC}"
        echo -e "${YELLOW}   Проверьте доступ к GitHub и повторите.${NC}"
    fi
    read -p "Нажмите Enter для возврата..."
}

function run_rebuild_nginx {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}    🔬  ПЕРЕСБОРКА NGINX С OPENSSL 3.5 (PQ TLS)  🔬   ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "Системный OpenSSL 3.0.x не умеет постквантовый обмен ключей"
    echo -e "(X25519MLKEM768). Клиенты iOS его предпочитают, и его отсутствие"
    echo -e "на self-SNI backend'е — заметный маркер для DPI-эвристик.\n"
    echo -e "${RED}⚠️  Операция долгая: 20-40 минут на 1 vCPU.${NC}"
    echo -e "${RED}⚠️  Подменяется системный бинарник nginx (с бэкапом и авто-откатом).${NC}"
    echo -e "${RED}⚠️  После неё пакет nginx замораживается (apt-mark hold) —"
    echo -e "    security-обновления придётся ставить вручную.${NC}\n"

    if [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ]; then
        echo -e "${YELLOW}⚠️  Ты НЕ в tmux/screen. Обрыв SSH прервёт сборку на середине.${NC}"
        echo -e "${YELLOW}    Рекомендую: tmux new -s nginx, затем вернуться сюда.${NC}\n"
    else
        echo -e "${GREEN}✓ Сессия в tmux/screen — обрыв SSH сборку не убьёт.${NC}\n"
    fi

    [ -f "$REBUILD_SCRIPT" ] || { echo -e "${RED}❌ Не найден $REBUILD_SCRIPT${NC}"; read -p "Enter..."; return; }

    read -p "$(echo -e "${RED}Введите СОБРАТЬ для подтверждения: ${NC}")" confirm
    if [ "$confirm" != "СОБРАТЬ" ]; then
        echo -e "${BLUE}Отменено.${NC}"; sleep 1; return
    fi

    bash "$REBUILD_SCRIPT"
    read -p "Нажмите Enter для возврата..."
}

function uninstall_stack {
    clear
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}          🗑️   УДАЛЕНИЕ СТЕКА TELEMT  🗑️              ${NC}"
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
        echo -e "${RED}⚠️  nginx -t не проходит — проверь конфиг вручную.${NC}"
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
        clear
        load_stack_conf
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}        ✈️   СТЕК TELEMT / MTPROTO  ✈️                ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "    telemt:         [$(stack_status_line)]"
        echo -e "    telemt_panel:   [$(panel_status_line)]"
        echo -e "    Маскировка:     [$(mask_status_line)]"
        echo -e "    MTproxy-reanim: [$(mtpr_status_line)]"
        if mtpr_is_installed; then
            echo -e "    ${BLUE}Запуск его менеджера — команда${NC} ${CYAN}mtpr${NC}${BLUE}, из любой точки системы.${NC}"
        fi
        if [ -n "$DOMAIN_PANEL" ]; then
            echo -e "    Домены:         ${YELLOW}${DOMAIN_PANEL}${NC} / ${YELLOW}${DOMAIN_REALITY}${NC}"
        fi
        echo -e "${BLUE}--- УСТАНОВКА ----------------------------------------${NC}"
        echo -e "${RED}1) 📦  Установить весь стек с нуля (СТИРАЕТ 3x-ui!)${NC}"
        echo -e "${GREEN}2) ➕  Добавить telemt к существующей 3x-ui-pro${NC}"
        echo -e "${BLUE}--- ЭКСПЛУАТАЦИЯ -------------------------------------${NC}"
        echo -e "${CYAN}3) 🩺  Статус и диагностика (проверка маскировки)${NC}"
        echo -e "${CYAN}4) 🔧  Восстановить маскировку (после патча панели)${NC}"
        echo -e "${CYAN}5) 🔑  Показать учётные данные${NC}"
        echo -e "${CYAN}6) ⚙️   Управление службами (старт | стоп | логи)${NC}"
        echo -e "${BLUE}--- ДОПОЛНИТЕЛЬНО ------------------------------------${NC}"
        echo -e "${YELLOW}7) 🛡️   MTproxy-reanimation (лимитер | тюнинг)${NC}"
        echo -e "${YELLOW}8) 🔬  Пересборка nginx с OpenSSL 3.5 (PQ TLS)${NC}"
        echo -e "${RED}9) 🗑️   Удалить стек telemt${NC}"
        echo -e "${RED}X) 🔙  Назад в главное меню${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"

        read -p "Ваш выбор [1-9, X]: " choice
        case $choice in
            1) run_install full ;;
            2) run_install addon ;;
            3) run_diagnostics ;;
            4) restore_mask ;;
            5) show_credentials ;;
            6) manage_services ;;
            7) run_mtpr ;;
            8) run_rebuild_nginx ;;
            9) uninstall_stack ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

run_telemt_menu
