#!/bin/bash
[ -f /usr/local/bin/_config_and_utils.sh ] || {
    echo "Не найден /usr/local/bin/_config_and_utils.sh — переустановите меню."; exit 1; }
source /usr/local/bin/_config_and_utils.sh

# ----------------------------------------------------------------------
# TELEGRAM-БОТЫ
#   3xui-telemt-bot — объединённый (рекомендуется)
#   telemt-bot      — только мониторинг панели Telemt
#   3xui-bot        — только панели 3x-ui
# Код общий для всех трёх, запускаются прямо из bots/.
# ----------------------------------------------------------------------

# Каталог репозитория — от расположения скрипта, а не жёстко: при запуске
# через симлинк readlink -f приводит к реальному файлу. Иначе установка
# под прежним именем после обновления не нашла бы свои скрипты.
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STACK_SCRIPT="$REPO_DIR/bots-stack.sh"
BOTS_DIR="$REPO_DIR/bots"
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
    read -p "Токен (Enter — оставить): " val
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
        echo -e "\n${CYAN}--- Карта подключений ---${NC}"
        echo -e "Домен, на котором отдавать карту. Он должен уже существовать в"
        echo -e "конфиге nginx — установщик добавит в него ${YELLOW}location /telemt-map${NC}."
        echo -e "${YELLOW}Пусто — карту не подключать.${NC}"
        read -p "Домен${MAP_DOMAIN:+ [$MAP_DOMAIN]}: " in_d
        ASK_MAP="${in_d:-$MAP_DOMAIN}"
    fi
    return 0
}

function run_install {
    local mode="$1"
    [ -f "$STACK_SCRIPT" ] || { echo -e "${RED}❌ Не найден $STACK_SCRIPT${NC}"; read -p "Enter..."; return; }

    clear
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
        echo -e "\n${YELLOW}⚠️  Панель Telemt не найдена. Бот установится, но будет"
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
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}          🔄  ОБНОВЛЕНИЕ КОДА БОТОВ  🔄              ${NC}"
    echo -e "${CYAN}======================================================${NC}"

    cd "$REPO_DIR" || { echo -e "${RED}❌ Нет $REPO_DIR${NC}"; read -p "Enter..."; return; }
    [ -d .git ] || { echo -e "${RED}❌ $REPO_DIR не git-репозиторий.${NC}"; read -p "Enter..."; return; }

    local dirty
    dirty=$(git status --porcelain -- bots/ 2>/dev/null)
    if [ -n "$dirty" ]; then
        echo -e "${RED}⚠️  В bots/ есть несохранённые изменения:${NC}"
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
    echo -e "${CYAN}            ⚙️   ТЕКУЩИЕ НАСТРОЙКИ  ⚙️                 ${NC}"
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

function manage_services {
    local units; units=$(installed_units)
    if [ -z "$units" ]; then
        echo -e "${RED}❌ Ни один бот не установлен.${NC}"; read -p "Enter..."; return
    fi
    echo -e "\n${CYAN}Установленные службы:${NC}"
    local i=1; local list=()
    for u in $units; do echo -e "  $i) $u [$(unit_status "$u")]"; list+=("$u"); i=$((i+1)); done
    read -p "Выбор [1-$((i-1)), X]: " ch
    [[ "$ch" =~ ^[Xx]$ ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && [ -n "${list[$((ch-1))]}" ] \
        && manage_service_status_restart "${list[$((ch-1))]}" \
        || { echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1; }
}

function run_remove {
    clear
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}            🗑️  УДАЛЕНИЕ БОТОВ  🗑️                    ${NC}"
    echo -e "${RED}======================================================${NC}"
    echo -e "Будут остановлены и удалены службы, окружение и настройки."
    echo -e "${YELLOW}Данные (история IP, список панелей, GeoIP) сохраняются"
    echo -e "в $DATA_DIR.${NC}"
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
    rm -rf "$BOTS_DIR/venv"; rm -f "$ENV_FILE" "$CONF"
    echo -e "${GREEN}✓ Службы, окружение и настройки удалены${NC}"
    echo -e "${YELLOW}! Данные оставлены в $DATA_DIR${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

# --- ГЛАВНОЕ МЕНЮ МОДУЛЯ ----------------------------------------------------
while true; do
    clear; load_conf
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}            🤖  TELEGRAM-БОТЫ  🤖                    ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e " 🤝  3xui-telemt-bot : [$(unit_status 3xui-telemt-bot)]"
    echo -e " ✈️   telemt-bot      : [$(unit_status telemt-bot)]"
    echo -e " 🎛️   3xui-bot        : [$(unit_status 3xui-monitor)]"
    echo -e " 🗺️   карта           : [$(map_status_line)]"
    echo -e "${BLUE}------------------------------------------------------${NC}"
    echo -e "${GREEN}1) 🤝  Объединённый бот (Telemt | панели 3x-ui)${NC}"
    echo -e "${YELLOW}2) 🔀  Два отдельных бота (telemt-bot | 3xui-bot)${NC}"
    echo -e "${YELLOW}3) ✈️   Только telemt-bot${NC}"
    echo -e "${YELLOW}4) 🎛️   Только 3xui-bot${NC}"
    echo -e "${CYAN}5) 🔄  Обновить код ботов (с GitHub)${NC}"
    echo -e "${GREEN}6) ⚙️   Показать текущие настройки${NC}"
    echo -e "${GREEN}7) 🛠️   Управление службами (статус | старт | стоп | логи)${NC}"
    echo -e "${RED}8) 🗑️   Удалить ботов${NC}"
    echo -e "${RED}X) 🔙  Назад в главное меню${NC}"
    echo -e "${BLUE}------------------------------------------------------${NC}"
    read -p "$(echo -e "${CYAN}Ваш выбор: ${NC}")" choice

    case $choice in
        1) run_install combined ;;
        2) run_install both ;;
        3) run_install telemt ;;
        4) run_install 3xui ;;
        5) run_update ;;
        6) show_settings ;;
        7) manage_services ;;
        8) run_remove ;;
        [Xx]) break ;;
        *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
    esac
done
