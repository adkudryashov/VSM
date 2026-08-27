#!/bin/bash
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh" || {
    echo "Не найдена lib/common.sh — переустановите VSM: bash install.sh"; exit 1; }

# ----------------------------------------------------------------------
# TELEGRAM-БОТЫ
#   3xui-telemt-bot — объединённый (рекомендуется)
#   telemt-bot      — только мониторинг панели Telemt
#   3xui-bot        — только панели 3x-ui
# Код общий для всех трёх, запускаются прямо из bots/.
# ----------------------------------------------------------------------

STACK_SCRIPT="$VSM_ROOT/stacks/bots.sh"
BOTS_DIR="$VSM_ROOT/bots"
DATA_DIR="$BOTS_DIR/data"
ENV_FILE="$BOTS_DIR/.env"
CONF="/etc/vsm/bots.conf"
MAP_DIR="/var/www/telemt-map"

function load_conf {
    COMBINED_BOT_TOKEN=""; TELEMT_BOT_TOKEN=""; XUI_BOT_TOKEN=""
    ADMIN_IDS=""; MAP_DOMAIN=""; BOTS_MODE=""
    # shellcheck disable=SC1090
    [ -f "$CONF" ] && source "$CONF"
}

function unit_status {
    local unit="$1"
    if [ ! -f "/etc/systemd/system/$unit.service" ]; then
        echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"
    elif systemctl is-active --quiet "$unit"; then
        echo -e "${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e "${YELLOW}ОСТАНОВЛЕН${NC}"
    fi
}

function map_status_line {
    if [ ! -f "$MAP_DIR/map.html" ]; then
        echo -e "${YELLOW}НЕ ПОСТРОЕНА${NC}"
    else
        echo -e "${GREEN}$(date -r "$MAP_DIR/map.html" '+%d.%m %H:%M')${NC}"
    fi
}

# --- Опрос параметров -------------------------------------------------------
# Токены не показываем: только «задан / не задан», Enter оставляет текущий.
function ask_token {
    local label="$1" current="$2"
    local mark; [ -n "$current" ] && mark="${GREEN}задан${NC}" || mark="${RED}не задан${NC}"
    echo -e "${CYAN}$label${NC} — токен от @BotFather. Текущий: $mark" >&2
    # БЕЗ ЭХА. Токен — это полный доступ к боту: чтение всех сообщений и
    # рассылка от его имени. Печатался он по мере набора и оседал в скроллбэке,
    # в записи сеанса и на любом снимке экрана. Именно так он утёк в переписку
    # на приёмке 27.08.2026.
    #
    # Пароль панели 3x-ui вводится без эха с самого начала; здесь про это
    # забыли, хотя секрет ровно того же веса.
    #
    # IFS= и -r по той же причине, что и там: без -r обратный слэш считается
    # экранированием и молча пропадает, без IFS= обрезаются крайние пробелы.
    IFS= read -rs -p "Токен (Enter — оставить): " val
    echo >&2
    echo "${val:-$current}"
}

function ask_params {
    local mode="$1"
    load_conf

    case "$mode" in
        combined)
            echo -e "\n${CYAN}--- Объединённый бот 3xui-telemt-bot ---${NC}"
            ASK_COMBINED=$(ask_token "3xui-telemt-bot" "$COMBINED_BOT_TOKEN")
            [ -z "$ASK_COMBINED" ] && { echo -e "${RED}❌ Токен обязателен.${NC}"; return 1; }
            ;;
        both|telemt|3xui)
            if [ "$mode" != "3xui" ]; then
                echo -e "\n${CYAN}--- telemt-bot ---${NC}"
                ASK_TELEMT=$(ask_token "telemt-bot" "$TELEMT_BOT_TOKEN")
                [ -z "$ASK_TELEMT" ] && { echo -e "${RED}❌ Токен обязателен.${NC}"; return 1; }
            fi
            if [ "$mode" != "telemt" ]; then
                echo -e "\n${CYAN}--- 3xui-bot ---${NC}"
                ASK_XUI=$(ask_token "3xui-bot" "$XUI_BOT_TOKEN")
                [ -z "$ASK_XUI" ] && { echo -e "${RED}❌ Токен обязателен.${NC}"; return 1; }
            fi
            ;;
    esac

    echo -e "\n${CYAN}--- Доступ ---${NC}"
    echo -e "${YELLOW}Telegram ID админов через запятую${NC} (узнать свой — @userinfobot)"
    echo -e "${YELLOW}Остальные пользователи игнорируются молча.${NC}"
    read -p "Admin IDs${ADMIN_IDS:+ [$ADMIN_IDS]}: " in_a
    ASK_IDS="${in_a:-$ADMIN_IDS}"
    if [ -z "$ASK_IDS" ]; then echo -e "${RED}❌ Нужен хотя бы один ID.${NC}"; return 1; fi
    if ! [[ "${ASK_IDS//[[:space:]]/}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo -e "${RED}❌ Только числа через запятую, например: 12345678,87654321${NC}"; return 1
    fi

    if [ "$mode" != "3xui" ]; then
        # СПРАШИВАЕМ НЕ «КАКОЙ ДОМЕН», А «КУДА ИЗ ЭТИХ».
        #
        # Прежний вопрос звучал так: «домен, на котором отдавать карту; он
        # должен уже существовать в конфиге nginx». Человеку, ставящему VSM
        # впервые, это не говорит ничего: он не знает, какие домены в nginx
        # есть, и тем более не знает, что один из них — цель self-SNI
        # маскировки и вешать на него карту нельзя. Владелец указал на это
        # прямо: «сейчас мы делаем вместе, а потом пользователь будет один».
        #
        # VSM знает и то, и другое. Значит выбор нужно ПОКАЗАТЬ, а не требовать
        # угадать. Свободный ввод оставлен для тех, у кого на сервере есть свои
        # домены помимо наших.
        local _mask_domain="" _cands=() _c
        [ -r /etc/vsm/telemt.conf ] && \
            _mask_domain="$(grep -m1 -oP '^DOMAIN_PANEL=\K.*' /etc/vsm/telemt.conf 2>/dev/null | tr -d "\"'")"

        # Берём имена из ЖИВОГО nginx, а не из нашего конфига: там могут быть
        # чужие сайты, и они годятся не хуже. Домен маскировки исключаем.
        while IFS= read -r _c; do
            [ -n "$_c" ] || continue
            [ "$_c" = "$_mask_domain" ] && continue
            _cands+=("$_c")
        done < <(
            # -R, а НЕ -r: sites-enabled состоит из символических ссылок, а
            # grep -r при обходе каталога их пропускает. С -r находился только
            # conf.d/telemt-mask.conf, то есть ровно домен маскировки, который
            # тут же исключается, — и список оказывался пуст. Поймано
            # владельцем на живом экране 27.08.2026.
            grep -RhoP '^\s*server_name\s+\K[^;]+' \
                 /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null \
            | tr ' ' '\n' | grep -vE '^(_|localhost)?$' | sort -u
        )

        echo -e "\n${CYAN}--- Карта подключений ---${NC}"
        echo -e "${C_DESC:-}Карта показывает города и провайдеров всех, кто подключался."
        echo -e "Отдаётся по секретному пути (telemt-map- плюс 24 случайных символа),"
        echo -e "как и веб-панели.${NC}"

        if [ -n "$_mask_domain" ]; then
            echo -e "${YELLOW}Домен ${_mask_domain} недоступен: это цель self-SNI маскировки.${NC}"
            echo -e "${C_DESC:-}   Маска копирует у него корень и TLS, но не location-блоки:"
            echo -e "   тот же адрес на 443 отдал бы 200, а через порт telemt — 404."
            echo -e "   Один запрос — и порт прокси опознан.${NC}"
        fi

        echo ""
        local _n=1 _i
        for _i in "${_cands[@]}"; do
            echo -e "   ${YELLOW}${_n})${NC} ${_i}"
            _n=$((_n + 1))
        done
        echo -e "   ${YELLOW}${_n})${NC} ввести другой домен"
        local _other=$_n
        echo -e "   ${YELLOW}0)${NC} не подключать карту"
        echo ""

        while true; do
            local _sel _def=""
            # Умолчание — единственный подходящий домен, если он один: тогда
            # выбирать не из чего, и лишний вопрос только сбивает.
            [ "${#_cands[@]}" -eq 1 ] && _def="1"
            read -p "Выбор${_def:+ [$_def]}: " _sel
            _sel="${_sel:-$_def}"
            if [ "$_sel" = "0" ]; then
                ASK_MAP=""; break
            elif [ "$_sel" = "$_other" ]; then
                read -p "Домен: " ASK_MAP
                if [ -n "$_mask_domain" ] && [ "$ASK_MAP" = "$_mask_domain" ]; then
                    echo -e "${RED}❌ Это домен маскировки — на него нельзя. Выберите другой.${NC}"
                    continue
                fi
                break
            elif [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -ge 1 ] && [ "$_sel" -le "${#_cands[@]}" ]; then
                ASK_MAP="${_cands[$((_sel - 1))]}"; break
            else
                echo -e "${RED}❌ Неверный выбор.${NC}"
            fi
        done
    fi
    return 0
}

function run_install {
    local mode="$1"
    [ -f "$STACK_SCRIPT" ] || { echo -e "${RED}❌ Не найден $STACK_SCRIPT${NC}"; read -p "Enter..."; return; }

    clear 2>/dev/null
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       🤖  УСТАНОВКА TELEGRAM-БОТОВ  🤖              ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    if [ "$mode" == "combined" ]; then
        echo -e "${GREEN}Один бот с обеими функциями. Разделы переключаются"
        echo -e "кнопками, есть общая сводка по всему.${NC}"
        echo -e "${YELLOW}Отдельные боты будут остановлены — иначе они дублировали бы"
        echo -e "сбор IP и опрос панелей. Данные общие, ничего не теряется.${NC}"
    else
        echo -e "${YELLOW}Объединённый бот будет остановлен, если он установлен.${NC}"
    fi
    echo -e "${GREEN}Повторный запуск безопасен: базы, настройки и GeoIP сохраняются.${NC}"

    if [ "$mode" != "3xui" ] && [ ! -f /etc/telemt/telemt.toml ]; then
        echo -e "\n${YELLOW}❗  Панель Telemt не найдена. Бот установится, но будет"
        echo -e "    писать в журнал ошибки обращения к её API.${NC}"
    fi

    ask_params "$mode" || { read -p "Enter..."; return; }
    echo -e "\n${YELLOW}Запускаю установку.${NC}\n"; sleep 1

    COMBINED_BOT_TOKEN="${ASK_COMBINED:-}" \
    TELEMT_BOT_TOKEN="${ASK_TELEMT:-}" \
    XUI_BOT_TOKEN="${ASK_XUI:-}" \
    ADMIN_IDS="${ASK_IDS:-}" \
    MAP_DOMAIN="${ASK_MAP:-}" \
        bash "$STACK_SCRIPT" --bots "$mode"

    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

function installed_units {
    local out=""
    for u in 3xui-telemt-bot telemt-bot 3xui-monitor; do
        [ -f "/etc/systemd/system/$u.service" ] && out="$out $u"
    done
    echo "$out"
}

function run_update {
    clear 2>/dev/null
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}          🔄  ОБНОВЛЕНИЕ КОДА БОТОВ  🔄              ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    cd "$VSM_ROOT" || { echo -e "${RED}❌ Нет $VSM_ROOT${NC}"; read -p "Enter..."; return; }
    [ -d .git ] || { echo -e "${RED}❌ $VSM_ROOT не git-репозиторий.${NC}"; read -p "Enter..."; return; }

    local dirty
    dirty=$(git status --porcelain -- bots/ 2>/dev/null)
    if [ -n "$dirty" ]; then
        echo -e "${RED}❗  В bots/ есть несохранённые изменения:${NC}"
        echo "$dirty" | sed 's/^/    /'
        echo -e "${YELLOW}Обновление их СОТРЁТ.${NC}"
        read -p "$(echo -e "${RED}Введите СТЕРЕТЬ, чтобы продолжить: ${NC}")" c
        [ "$c" != "СТЕРЕТЬ" ] && { echo -e "${BLUE}Отменено.${NC}"; sleep 1; return; }
    fi

    echo -e "${YELLOW}>>> Забираю изменения с GitHub...${NC}"
    git fetch origin main &>/dev/null || { echo -e "${RED}❌ Нет связи с GitHub.${NC}"; read -p "Enter..."; return; }

    local before after
    before=$(git rev-parse HEAD)
    git reset --hard origin/main >/dev/null || { echo -e "${RED}❌ Не удалось обновить.${NC}"; read -p "Enter..."; return; }
    after=$(git rev-parse HEAD)

    if [ "$before" == "$after" ]; then
        echo -e "${GREEN}✓ Уже последняя версия.${NC}"
    else
        echo -e "${GREEN}✓ Обновлено:${NC}"; git log --oneline "$before..$after" | sed 's/^/    /'
    fi

    if [ -x "$BOTS_DIR/venv/bin/pip" ]; then
        echo -e "${YELLOW}>>> Проверяю зависимости...${NC}"
        "$BOTS_DIR/venv/bin/pip" install -q -r "$BOTS_DIR/requirements.txt" \
            && echo -e "${GREEN}    ✓ актуальны${NC}" \
            || echo -e "${RED}    ✗ ошибка установки зависимостей${NC}"
    fi

    local units; units=$(installed_units)
    if [ -z "$units" ]; then
        echo -e "${YELLOW}! Ни один бот не установлен — перезапускать нечего.${NC}"
    else
        echo -e "${YELLOW}>>> Перезапускаю службы...${NC}"
        local ok=1
        for unit in $units; do
            systemctl restart "$unit"; sleep 6
            if [ "$(systemctl is-active "$unit")" == "active" ]; then
                echo -e "${GREEN}    ✓ $unit работает${NC}"
            else
                echo -e "${RED}    ✗ $unit не поднялся${NC}"
                journalctl -u "$unit" -n 10 --no-pager -o cat | sed 's/^/      /'
                ok=0
            fi
        done
        [ $ok -eq 1 ] && echo -e "\n${GREEN}✅ Обновление завершено.${NC}" \
                      || echo -e "\n${RED}❌ Бот не запустился — смотрите журнал выше.${NC}"
    fi
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

function show_settings {
    clear; load_conf
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}            🔧   ТЕКУЩИЕ НАСТРОЙКИ  🔧                 ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e " Режим             : ${YELLOW}${BOTS_MODE:-не установлен}${NC}"
    echo -e " Каталог кода      : ${YELLOW}$BOTS_DIR${NC}"
    echo -e " Каталог данных    : ${YELLOW}$DATA_DIR${NC}"
    echo -e " Конфиг ботов      : ${YELLOW}$ENV_FILE${NC} (600)"
    echo -e " Настройки меню    : ${YELLOW}$CONF${NC} (600)"
    echo -e " Токен объединён.  : $([ -n "$COMBINED_BOT_TOKEN" ] && echo -e "${GREEN}задан${NC}" || echo -e "${RED}нет${NC}")"
    echo -e " Токен telemt      : $([ -n "$TELEMT_BOT_TOKEN" ] && echo -e "${GREEN}задан${NC}" || echo -e "${RED}нет${NC}")"
    echo -e " Токен 3xui        : $([ -n "$XUI_BOT_TOKEN" ] && echo -e "${GREEN}задан${NC}" || echo -e "${RED}нет${NC}")"
    echo -e " Админы            : ${YELLOW}${ADMIN_IDS:-—}${NC}"
    echo -e " Домен карты       : ${YELLOW}${MAP_DOMAIN:-не настроен}${NC}"
    echo -e " Карта обновлена   : $(map_status_line)"
    if [ -f "$DATA_DIR/ip_history.db" ]; then
        echo -e " История IP        : ${YELLOW}$(sqlite3 "$DATA_DIR/ip_history.db" "SELECT COUNT(*) FROM ip_log;" 2>/dev/null || echo '?') записей${NC}"
    fi
    if [ -f "$DATA_DIR/bot_monitor.db" ]; then
        echo -e " Панелей 3x-ui     : ${YELLOW}$(sqlite3 "$DATA_DIR/bot_monitor.db" "SELECT COUNT(*) FROM panels;" 2>/dev/null || echo '?')${NC}"
    fi
    echo -e "${BLUE}------------------------------------------------------${NC}"
    echo -e "${YELLOW}Токены не показываются. Чтобы сменить — переустановите"
    echo -e "нужный режим и введите новое значение вместо Enter.${NC}"
    echo ""
    read -p "Нажмите Enter для возврата..."
}

# ----------------------------------------------------------------------
# СТОРОЖ TELEMT
#
# Значение пишется в ДВА файла. bots.conf — источник правды: оттуда его берёт
# stacks/bots.sh, который при каждой установке создаёт .env заново. .env —
# то, что бот читает прямо сейчас. Записать только в .env значит потерять
# настройку при первой переустановке режима; только в bots.conf — не увидеть
# её до следующей установки.
# ----------------------------------------------------------------------
function _wd_set {
    local key="$1" value="$2" file
    for file in "$CONF" "$ENV_FILE"; do
        [ -f "$file" ] || continue
        if grep -q "^${key}=" "$file"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$file"
        else
            printf '%s=%s\n' "$key" "$value" >> "$file"
        fi
    done
}

function _wd_get {
    local key="$1"
    [ -f "$CONF" ] || { echo ""; return; }
    grep -m1 -oP "^${key}=\K.*" "$CONF" 2>/dev/null | tr -d "'\""
}

function _wd_restart {
    local units; units=$(installed_units)
    if [ -z "$units" ]; then
        echo -e "${YELLOW}Боты не установлены — настройка сохранена и применится при установке.${NC}"
        return
    fi
    echo -e "${YELLOW}>>> Перезапускаю службы, чтобы настройка вступила в силу...${NC}"
    for u in $units; do systemctl restart "$u" 2>/dev/null; done
    sleep 3
    # По факту, а не по коду возврата: служба умеет упасть сразу после старта.
    for u in $units; do
        if [ "$(systemctl is-active "$u")" = "active" ]; then
            echo -e "${GREEN}✓ $u работает${NC}"
        else
            echo -e "${RED}✗ $u не поднялась — journalctl -u $u -n 20${NC}"
        fi
    done
}

function manage_watchdog {
    while true; do
        clear 2>/dev/null
        ui_title "🛡  СТОРОЖ TELEMT"

        local wd ru iv pr tok port sni wd_t wd_c ru_t ru_c
        wd=$(_wd_get WATCHDOG_ENABLED); ru=$(_wd_get RU_CHECK_ENABLED)
        iv=$(_wd_get RU_CHECK_INTERVAL_MINUTES); pr=$(_wd_get RU_CHECK_PROBES)
        tok=$(_wd_get RU_CHECK_TOKEN); port=$(_wd_get RU_CHECK_PORT); sni=$(_wd_get RU_CHECK_SNI)
        if [ "$wd" = "true" ]; then wd_t="ВКЛЮЧЁН"; wd_c="$C_OK"; else wd_t="ВЫКЛЮЧЕН"; wd_c="$C_DANGER"; fi
        if [ "$ru" = "true" ]; then ru_t="ВКЛЮЧЕНА"; ru_c="$C_OK"; else ru_t="ВЫКЛЮЧЕНА"; ru_c="$C_DESC"; fi

        echo ""
        ui_section "СОСТОЯНИЕ"
        echo -e "   ${C_NAME}$(ui_pad '🛡  Сторож' 24)${NC}${wd_c}${wd_t}${NC}"
        echo -e "   ${C_NAME}$(ui_pad '🇷🇺  Доступность из РФ' 24)${NC}${ru_c}${ru_t}${NC}"
        if [ "$ru" = "true" ]; then
            ui_kv '⏱  Интервал' "${iv:-60} мин" 24
            ui_kv '📡  Зондов за прогон' "${pr:-10}" 24
            ui_kv '🔑  Токен Globalping' "$([ -n "$tok" ] && echo 'задан' || echo 'нет (бюджет 250/час)')" 24
            ui_kv '🎯  Цель проверки' "${sni:-?}:${port:-?}" 24
        fi

        echo ""
        ui_section "ЧТО СТОРОЖ ПРИСЫЛАЕТ САМ"
        echo -e "   ${C_DESC}движок недоступен · перезапустился · просели писатели${NC}"
        echo -e "   ${C_DESC}изменился конфиг движка · сменился внешний адрес${NC}"
        echo -e "   ${C_DESC}Команды в боте: /watch /check /mute /unmute${NC}"

        echo ""
        ui_section "НАСТРОЙКА"
        ui_item "1" "🛡" "Сторож" "Включить или выключить наблюдение и тревоги"
        ui_item "2" "🇷🇺" "Доступность из РФ" "Зонды Globalping — см. предупреждение"
        ui_item "3" "⏱" "Интервал и зонды" "Как часто и сколькими зондами проверять"
        ui_item "4" "🔑" "Токен Globalping" "Поднимает часовой бюджет проверок"
        echo ""
        ui_item "X" "🔙" "Назад"
        echo ""

        read -p "Ваш выбор [1-4, X]: " ch
        case "$ch" in
            1)
                if [ "$wd" = "true" ]; then
                    _wd_set WATCHDOG_ENABLED false
                    echo -e "${YELLOW}Сторож выключен: тревоги приходить не будут.${NC}"
                else
                    _wd_set WATCHDOG_ENABLED true
                    echo -e "${GREEN}Сторож включён.${NC}"
                fi
                _wd_restart; read -p "Enter..."
                ;;
            2)
                if [ "$ru" = "true" ]; then
                    _wd_set RU_CHECK_ENABLED false
                    echo -e "${YELLOW}Проверка доступности выключена.${NC}"
                    _wd_restart; read -p "Enter..."
                    continue
                fi
                # Цена названа до включения и полностью, а не сноской после.
                echo ""
                echo -e "${RED}❗  Чем это оплачивается:${NC}"
                echo -e "${YELLOW}    Каждый прогон просит публичный сервис Globalping подключиться"
                echo -e "    к вашему прокси с домашних адресов российских провайдеров."
                echo -e "    То есть к серверу идёт внешний трафик ПО РАСПИСАНИЮ, а его"
                echo -e "    адрес, порт и домен маскировки уходят в стороннее API.${NC}"
                echo -e "${GREEN}    Взамен: это единственный сигнал про ВХОД — видят ли вас"
                echo -e "    клиенты. Всё остальное меряет только выход к Telegram.${NC}"
                echo ""
                read -p "$(echo -e "${RED}Введите ВКЛЮЧИТЬ для подтверждения: ${NC}")" c
                if [ "$c" != "ВКЛЮЧИТЬ" ]; then
                    echo -e "${BLUE}Отменено.${NC}"; sleep 1; continue
                fi
                _wd_set RU_CHECK_ENABLED true
                # Цель берём из конфига стека: руками её вводить незачем.
                local p d
                p=$(grep -m1 -oP '^TELEMT_PORT=\K.*' /etc/vsm/telemt.conf 2>/dev/null | tr -dc '0-9')
                d=$(grep -m1 -oP '^DOMAIN_PANEL=\K.*' /etc/vsm/telemt.conf 2>/dev/null | tr -d "'\"")
                [ -n "$p" ] && _wd_set RU_CHECK_PORT "$p"
                [ -n "$d" ] && _wd_set RU_CHECK_SNI "$d"
                if [ -z "$p" ] || [ -z "$d" ]; then
                    echo -e "${RED}❗  Не нашёл порт или домен в /etc/vsm/telemt.conf —${NC}"
                    echo -e "${RED}    проверка не заработает, пока стек telemt не настроен.${NC}"
                else
                    echo -e "${GREEN}Проверка включена. Цель: ${d}:${p}${NC}"
                fi
                _wd_restart; read -p "Enter..."
                ;;
            3)
                read -p "Интервал в минутах [${iv:-60}]: " a; a="${a:-${iv:-60}}"
                read -p "Зондов за прогон [${pr:-10}]: " b; b="${b:-${pr:-10}}"
                if ! [[ "$a" =~ ^[0-9]+$ ]] || ! [[ "$b" =~ ^[0-9]+$ ]] || [ "$a" -lt 1 ] || [ "$b" -lt 1 ]; then
                    echo -e "${RED}❌ Нужны положительные числа.${NC}"; sleep 2; continue
                fi
                if [ "$b" -gt 50 ]; then
                    echo -e "${RED}❌ Globalping принимает не больше 50 зондов за прогон.${NC}"; sleep 2; continue
                fi
                # Считаем бюджет ДО сохранения: сервис не откажет частично, он
                # откажет целиком, и узнать об этом в бою дороже.
                local budget=250; [ -n "$tok" ] && budget=500
                local per_hour=$(( (60 / a) * b ))
                echo -e "${BLUE}Расход: ~${per_hour} кредитов в час при бюджете ${budget}.${NC}"
                if [ "$per_hour" -gt "$budget" ]; then
                    echo -e "${RED}❗  Это больше бюджета — часть проверок будет пропущена.${NC}"
                    read -p "$(echo -e "${YELLOW}Всё равно сохранить? [y/N]: ${NC}")" y
                    [[ ! "$y" =~ ^[Yy]$ ]] && { echo -e "${BLUE}Отменено.${NC}"; sleep 1; continue; }
                fi
                _wd_set RU_CHECK_INTERVAL_MINUTES "$a"
                _wd_set RU_CHECK_PROBES "$b"
                _wd_restart; read -p "Enter..."
                ;;
            4)
                echo -e "${BLUE}Бесплатный токен: https://dash.globalping.io/${NC}"
                echo -e "${YELLOW}Пустой ввод стирает сохранённый.${NC}"
                read -p "Токен: " t
                _wd_set RU_CHECK_TOKEN "$t"
                echo -e "${GREEN}Сохранено.${NC}"
                _wd_restart; read -p "Enter..."
                ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

function manage_services {
    local units; units=$(installed_units)
    if [ -z "$units" ]; then
        echo -e "${RED}❌ Ни один бот не установлен.${NC}"; read -p "Enter..."; return
    fi
    echo -e "\n${CYAN}Установленные службы:${NC}"
    local i=1; local list=()
    # Список собирается на лету, но рисуется теми же примитивами: экран, где
    # пункты выглядят иначе, чем везде, читается как чужой, и клавиша выхода
    # там ищется отдельно.
    for u in $units; do
        ui_item "$i" "⚙" "$u" "$(unit_status "$u")"
        list+=("$u"); i=$((i+1))
    done
    ui_item "X" "🔙" "Назад"
    read -p "Выбор [1-$((i-1)), X]: " ch
    [[ "$ch" =~ ^[Xx]$ ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && [ -n "${list[$((ch-1))]}" ] \
        && manage_service_status_restart "${list[$((ch-1))]}" \
        || { echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1; }
}

function run_remove {
    clear 2>/dev/null
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}            🧨  УДАЛЕНИЕ БОТОВ  🧨                    ${NC}"
    echo -e "${RED}======================================================${NC}"
    echo -e "Будут остановлены и удалены службы, окружение и настройки."
    echo -e "Также снимается публичная отдача карты: файл и блок в конфиге nginx."
    echo -e "${YELLOW}Данные (история IP, список панелей, GeoIP) сохраняются"
    echo -e "в $DATA_DIR.${NC}"
    echo ""
    # Про токены сказано отдельно и до подтверждения.
    #
    # Удаление снимает и /etc/vsm/bots.conf, и bots/.env — а больше токен нигде
    # не хранится. То есть поставить ботов обратно без похода к @BotFather
    # нельзя. Прежний текст обещал «службы, окружение и настройки» и о
    # невозвратности молчал; выяснилось это прогоном разрушающих пунктов на
    # стенде, когда восстановить ботов уже было нечем.
    echo -e "${RED}❗  Токены будут удалены вместе с настройками.${NC}"
    echo -e "${RED}    Больше они нигде не хранятся: чтобы поставить ботов${NC}"
    echo -e "${RED}    обратно, понадобится взять токен у @BotFather заново.${NC}"
    echo -e "${YELLOW}    Сохранить сейчас: пункт «Настройки» в меню ботов.${NC}"
    echo ""
    read -p "$(echo -e "${RED}Введите УДАЛИТЬ для подтверждения: ${NC}")" c
    [ "$c" != "УДАЛИТЬ" ] && { echo -e "${BLUE}Отменено.${NC}"; sleep 1; return; }

    for unit in 3xui-telemt-bot telemt-bot 3xui-monitor; do
        if [ -f "/etc/systemd/system/$unit.service" ]; then
            systemctl disable --now "$unit" &>/dev/null
            rm -f "/etc/systemd/system/$unit.service"
            echo -e "${GREEN}✓ $unit удалён${NC}"
        fi
    done
    systemctl daemon-reload

    # Карта — единственное, что бот отдавал В ИНТЕРНЕТ, и раньше она удаление
    # переживала: файл со списком IP всех пользователей и location в nginx
    # оставались на месте. Владелец сворачивал ботов (нередко именно из
    # соображений приватности), видел зелёные галочки — а снимок продолжал
    # отдаваться по HTTPS бессрочно и незаметно, потому что в меню его больше
    # ничто не показывало.
    # Домен не передаём: блок ищется по маркеру во всех конфигах nginx. Иначе
    # при смене домена карты прежний блок остался бы работать навсегда.
    if command -v nginx >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        local out
        if out=$(python3 "$BOTS_DIR/telemt/scripts/nginx_map_location.py" \
                   --remove 2>&1); then
            nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
            echo -e "${GREEN}✓ Отдача карты снята из nginx${NC}"
        else
            echo -e "${RED}✗ Блок карты снять не удалось:${NC}"
            echo "$out" | sed 's/^/    /'
            echo -e "${YELLOW}  Проверьте вручную: grep -rn telemt-map /etc/nginx${NC}"
        fi
    fi
    rm -rf /var/www/telemt-map
    rm -rf "$BOTS_DIR/venv"; rm -f "$ENV_FILE" "$CONF"
    echo -e "${GREEN}✓ Службы, окружение, карта и настройки удалены${NC}"
    echo -e "${YELLOW}! Данные оставлены в $DATA_DIR${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

# --- ГЛАВНОЕ МЕНЮ МОДУЛЯ ----------------------------------------------------
while true; do
    clear; load_conf
    ui_title "🤖  TELEGRAM-БОТЫ"
    echo ""
    echo -e "   ${C_NAME}$(ui_pad '🤝  3xui-telemt-bot' 22)${NC}$(unit_status 3xui-telemt-bot)"
    echo -e "   ${C_NAME}$(ui_pad '🛫  telemt-bot' 22)${NC}$(unit_status telemt-bot)"
    echo -e "   ${C_NAME}$(ui_pad '📊  3xui-bot' 22)${NC}$(unit_status 3xui-monitor)"
    echo -e "   ${C_NAME}$(ui_pad '🌍  Карта подключений' 22)${NC}$(map_status_line)"
    echo ""
    ui_section "РЕЖИМ РАБОТЫ"
    ui_item "1" "🤝" "Объединённый бот" "Telemt и панели 3x-ui в одном боте"
    ui_item "2" "🔀" "Два отдельных"    "telemt-bot и 3xui-bot по разным токенам"
    ui_item "3" "🛫" "Только telemt-bot" "Мониторинг MTProto-прокси"
    ui_item "4" "📊" "Только 3xui-bot"  "Мониторинг панелей 3x-ui"
    echo ""
    ui_section "ОБСЛУЖИВАНИЕ"
    ui_item "5" "🔄" "Обновить код"     "Забрать свежие исходники ботов с GitHub"
    ui_item "6" "🛡" "Сторож"           "Тревоги и доступность прокси из России"
    ui_item "7" "🔧" "Настройки"        "Показать текущие токены и параметры"
    ui_item "8" "🧰" "Управление"       "Статус, старт, стоп, журналы"
    echo ""
    ui_danger_item "9" "Удалить ботов"  "Службы, окружение, данные карты"
    ui_item "X" "🔙" "Назад"
    echo ""
    read -p "$(echo -e "${CYAN}Ваш выбор: ${NC}")" choice

    case $choice in
        1) run_install combined ;;
        2) run_install both ;;
        3) run_install telemt ;;
        4) run_install 3xui ;;
        5) run_update ;;
        6) manage_watchdog ;;
        7) show_settings ;;
        8) manage_services ;;
        9) run_remove ;;
        [Xx]) break ;;
        *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
    esac
done
