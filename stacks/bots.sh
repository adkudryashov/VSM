#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# УСТАНОВЩИК TELEGRAM-БОТОВ
#
# Встроен в VSM (пункт "Telegram-боты"), запускается локально.
# Неинтерактивный: параметры приходят через переменные окружения, спрашивает
# пользователя menus/bots.sh.
#
# РЕЖИМЫ (--bots):
#   combined — один бот 3xui-telemt-bot с обеими функциями (по умолчанию)
#   both     — два отдельных бота, как раньше
#   telemt   — только telemt-bot
#   3xui     — только 3xui-bot
#
# Объединённый и отдельные боты взаимоисключающие: иначе два процесса
# дублировали бы сбор IP и опрос панелей.
#
# ПЕРЕМЕННЫЕ (пустые берутся из ранее сохранённого bots.conf):
#   COMBINED_BOT_TOKEN  токен объединённого бота
#   TELEMT_BOT_TOKEN    токен отдельного telemt-бота
#   XUI_BOT_TOKEN       токен отдельного 3xui-бота
#   ADMIN_IDS           Telegram ID админов через запятую: 123,456
#   MAP_DOMAIN          домен для карты (пусто — nginx не трогать)
# ============================================================================

# readlink -f обязателен, а два dirname — потому что скрипт лежит в stacks/,
# а код ботов в bots/ рядом с ним на уровень выше.
#
# Раньше здесь стоял простой dirname без разыменования. Выстрелить не успело —
# звали всегда по настоящему пути, — но install.sh раскладывал в /usr/local/bin
# и этот файл тоже, и запуск по ссылке дал бы BOTS_DIR=/usr/local/bin/bots,
# которого нет.
VSM_ROOT="$(cd "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")" && pwd)"
BOTS_DIR="$VSM_ROOT/bots"
DATA_DIR="$BOTS_DIR/data"
VENV="$BOTS_DIR/venv"
ENV_FILE="$BOTS_DIR/.env"
CONF_DIR="/etc/vsm"
CONF="$CONF_DIR/bots.conf"

# Карта не может лежать в /root: права 700, nginx под www-data не пройдёт.
MAP_DIR="/var/www/telemt-map"
MAP_FILE="$MAP_DIR/map.html"

log()  { echo -e "\e[1;32m[этап]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m    $*"; }
die()  { echo -e "\e[1;31m[СБОЙ]\e[0m $*" >&2; exit 1; }

MODE="combined"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bots) MODE="${2:-combined}"; shift 2 ;;
        *)      shift ;;
    esac
done
case "$MODE" in combined|both|telemt|3xui) ;; *) MODE="combined" ;; esac

[[ "$(id -u)" -eq 0 ]] || die "Запускай под root."
[[ -d "$BOTS_DIR" ]]   || die "Не найден каталог с ботами: $BOTS_DIR"

mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
mkdir -p "$DATA_DIR"

conf_get() {
    [[ -f "$CONF" ]] || return 0
    ( set +u; . "$CONF"; echo "${!1:-}" )
}
COMBINED_BOT_TOKEN="${COMBINED_BOT_TOKEN:-$(conf_get COMBINED_BOT_TOKEN)}"
TELEMT_BOT_TOKEN="${TELEMT_BOT_TOKEN:-$(conf_get TELEMT_BOT_TOKEN)}"
XUI_BOT_TOKEN="${XUI_BOT_TOKEN:-$(conf_get XUI_BOT_TOKEN)}"
ADMIN_IDS="${ADMIN_IDS:-$(conf_get ADMIN_IDS)}"
MAP_DOMAIN="${MAP_DOMAIN:-$(conf_get MAP_DOMAIN)}"

# Секретный префикс пути к карте. Переиспользуется между запусками: смена
# ломает ссылку, уже сохранённую в Telegram у администратора.
MAP_PATH="${MAP_PATH:-$(conf_get MAP_PATH)}"
MAP_PATH="${MAP_PATH:-telemt-map-$(openssl rand -hex 12)}"

# --- Настройки сторожа -------------------------------------------------------
# Читаются из bots.conf и пишутся обратно, потому что и .env, и сам bots.conf
# этот скрипт создаёт ЗАНОВО при каждом запуске. Без переноса переустановка
# любого режима бота молча гасила бы сторож и стирала настройки проверки — а
# заметить это можно было бы только по тому, что тревоги перестали приходить.
WATCHDOG_ENABLED="${WATCHDOG_ENABLED:-$(conf_get WATCHDOG_ENABLED)}"
WATCHDOG_ENABLED="${WATCHDOG_ENABLED:-false}"
RU_CHECK_ENABLED="${RU_CHECK_ENABLED:-$(conf_get RU_CHECK_ENABLED)}"
RU_CHECK_ENABLED="${RU_CHECK_ENABLED:-false}"
RU_CHECK_INTERVAL_MINUTES="${RU_CHECK_INTERVAL_MINUTES:-$(conf_get RU_CHECK_INTERVAL_MINUTES)}"
RU_CHECK_INTERVAL_MINUTES="${RU_CHECK_INTERVAL_MINUTES:-60}"
RU_CHECK_PROBES="${RU_CHECK_PROBES:-$(conf_get RU_CHECK_PROBES)}"
RU_CHECK_PROBES="${RU_CHECK_PROBES:-10}"
RU_CHECK_TOKEN="${RU_CHECK_TOKEN:-$(conf_get RU_CHECK_TOKEN)}"

RU_CHECK_PORT="${RU_CHECK_PORT:-$(conf_get RU_CHECK_PORT)}"
RU_CHECK_SNI="${RU_CHECK_SNI:-$(conf_get RU_CHECK_SNI)}"

# Домен панели из конфига стека — нужен, чтобы отказаться вешать карту на цель
# self-SNI маскировки. Читаем в подоболочке и только одно значение.
conf_get_stack() {
    [[ -r /etc/vsm/telemt.conf ]] || return 0
    # shellcheck disable=SC1091
    ( . /etc/vsm/telemt.conf 2>/dev/null; printf '%s' "${!1:-}" )
}

# Порт и SNI для проверки доступности берём из конфига стека, а не спрашиваем:
# это те же значения, по которым к прокси ходят настоящие клиенты, и вводить их
# руками значит однажды ошибиться и проверять не тот адрес.
#
# Стоит ПОСЛЕ определения conf_get_stack: в bash функция обязана быть объявлена
# до вызова, а не просто присутствовать в файле.
if [[ -z "$RU_CHECK_PORT" ]]; then RU_CHECK_PORT="$(conf_get_stack TELEMT_PORT)"; fi
if [[ -z "$RU_CHECK_SNI"  ]]; then RU_CHECK_SNI="$(conf_get_stack DOMAIN_PANEL)"; fi

want_combined() { [[ "$MODE" == "combined" ]]; }
want_telemt()   { [[ "$MODE" == "both" || "$MODE" == "telemt" ]]; }
want_xui()      { [[ "$MODE" == "both" || "$MODE" == "3xui"   ]]; }
# Карта и GeoIP нужны везде, где есть telemt-функциональность
uses_telemt()   { want_combined || want_telemt; }

# Проверки через if, а не «условие && die»: при set -e ложное условие
# в конце такой цепочки само по себе обрывает скрипт.
[[ -n "$ADMIN_IDS" ]] || die "Не задан ADMIN_IDS"
if want_combined && [[ -z "$COMBINED_BOT_TOKEN" ]]; then die "Не задан COMBINED_BOT_TOKEN"; fi
if want_telemt   && [[ -z "$TELEMT_BOT_TOKEN"   ]]; then die "Не задан TELEMT_BOT_TOKEN";   fi
if want_xui      && [[ -z "$XUI_BOT_TOKEN"      ]]; then die "Не задан XUI_BOT_TOKEN";      fi

# --- 0. Перенос данных из прежней раскладки ---------------------------------
# Раньше у каждого бота был свой каталог с базой и своим venv. Теперь данные
# общие, иначе переключение между режимами теряло бы историю и панели.
migrate_old_layout() {
    local moved=0
    # Останавливаем работающих ботов до переноса: иначе старый процесс, у
    # которого база уходит из-под ног, тут же создаёт на её месте пустой файл,
    # и в каталоге остаётся мусор. Установщик всё равно перезапустит службы.
    for unit in 3xui-telemt-bot telemt-bot 3xui-monitor; do
        if [[ -f "/etc/systemd/system/$unit.service" ]]; then
            systemctl stop "$unit" 2>/dev/null || true
        fi
    done
    for pair in "telemt-bot/ip_history.db:ip_history.db" \
                "telemt-bot/activity.db:activity.db" \
                "3xui-bot/bot_monitor.db:bot_monitor.db"; do
        local src="$BOTS_DIR/${pair%%:*}" dst="$DATA_DIR/${pair#*:}"
        if [[ -f "$src" && ! -f "$dst" ]]; then
            mv "$src" "$dst"; moved=1
        fi
    done
    if [[ -d "$BOTS_DIR/telemt-bot/geoip" && ! -d "$DATA_DIR/geoip" ]]; then
        mv "$BOTS_DIR/telemt-bot/geoip" "$DATA_DIR/geoip"; moved=1
    fi
    # Старые venv больше не нужны: окружение теперь общее
    rm -rf "$BOTS_DIR/telemt-bot/venv" "$BOTS_DIR/3xui-bot/venv" 2>/dev/null || true
    rm -f  "$BOTS_DIR/telemt-bot/.env" "$BOTS_DIR/3xui-bot/config.py" 2>/dev/null || true
    # Каталоги прежней раскладки целиком: код из них уехал в telemt/ и xui/
    # при обновлении, данные — в data/ выше. Остаётся только мусор.
    rm -rf "$BOTS_DIR/telemt-bot" "$BOTS_DIR/3xui-bot" 2>/dev/null || true
    [[ $moved -eq 1 ]] && log "Данные перенесены в общий каталог $DATA_DIR"
    return 0
}
migrate_old_layout

# --- 1. Системные зависимости ------------------------------------------------
log "Проверяю системные пакеты"
NEED=()
command -v python3 >/dev/null || NEED+=(python3)
# Проверяем ensurepip, а не venv: модуль venv лежит в стандартной библиотеке и
# импортируется даже там, где пакета python3-venv нет. Создать окружение при
# этом нельзя — ensurepip приходит именно с этим пакетом. Из-за проверки не по
# тому модулю python3-venv никогда не попадал в список к установке, и на чистой
# Ubuntu установка ботов падала на создании venv.
python3 -c 'import ensurepip' 2>/dev/null || NEED+=(python3-venv)
command -v wget >/dev/null || NEED+=(wget)
if [[ ${#NEED[@]} -gt 0 ]]; then
    log "Ставлю: ${NEED[*]}"
    # На свежем VPS блокировку dpkg держит unattended-upgrades, и без ожидания
    # пакеты молча не ставятся — а без python3-venv бот просто не соберётся.
    _waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
                /var/lib/apt/lists/lock &>/dev/null; do
        [[ $_waited -eq 0 ]] && log "жду освобождения apt (идут автообновления)..."
        sleep 3; _waited=$((_waited + 3))
        [[ $_waited -ge 300 ]] && { log "apt занят дольше 300 с, продолжаю."; break; }
    done
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED[@]}" >/dev/null
fi
log "Python $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"

# --- 2. Общее окружение ------------------------------------------------------
# Проверяем и pip, а не только python. Упавшая попытка оставляет полуфабрикат:
# каталог и bin/python уже созданы, а на ensurepip всё обрывается, и pip не
# появляется. Проверка по одному bin/python принимала такой остаток за готовое
# окружение, пропускала пересоздание — и следующий запуск падал уже на pip,
# хотя меню обещает, что повторный запуск безопасен.
#
# --clear вычищает содержимое перед созданием, поэтому битый остаток чинится
# сам, без ручного удаления каталога.
if [[ ! -x "$VENV/bin/python" || ! -x "$VENV/bin/pip" ]]; then
    log "Создаю виртуальное окружение"
    python3 -m venv --clear "$VENV" || die "не удалось создать venv"
fi
log "Устанавливаю зависимости"
"$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/pip" install -q -r "$BOTS_DIR/requirements.txt" \
    || die "не удалось установить зависимости из requirements.txt"

# --- 3. Конфигурация ---------------------------------------------------------
ids_to_json() { local raw="${1//[[:space:]]/}"; echo "[${raw%,}]"; }

log "Пишу $ENV_FILE"
umask 077
cat > "$ENV_FILE" <<EOF
# Создан установщиком VSM. Общий конфиг всех точек входа.
COMBINED_BOT_TOKEN=$COMBINED_BOT_TOKEN
TELEMT_BOT_TOKEN=$TELEMT_BOT_TOKEN
XUI_BOT_TOKEN=$XUI_BOT_TOKEN
ADMIN_IDS=$(ids_to_json "$ADMIN_IDS")

TELEMT_API_URL=http://127.0.0.1:9091
TELEMT_API_KEY=
PROMETHEUS_METRICS_URL=http://127.0.0.1:9090/metrics
COLLECT_INTERVAL_MINUTES=1
ACTIVITY_RETENTION_HOURS=0
MAP_HTML_PATH=$MAP_FILE
WEB_URL=${MAP_DOMAIN:+https://$MAP_DOMAIN/$MAP_PATH/}

WATCHDOG_ENABLED=$WATCHDOG_ENABLED
RU_CHECK_ENABLED=$RU_CHECK_ENABLED
RU_CHECK_INTERVAL_MINUTES=$RU_CHECK_INTERVAL_MINUTES
RU_CHECK_PROBES=$RU_CHECK_PROBES
RU_CHECK_TOKEN=$RU_CHECK_TOKEN
RU_CHECK_PORT=$RU_CHECK_PORT
RU_CHECK_SNI=$RU_CHECK_SNI
EOF
chmod 600 "$ENV_FILE"

# --- 4. Базы GeoIP -----------------------------------------------------------
fetch_geoip() {
    uses_telemt || return 0
    if [[ -f "$DATA_DIR/geoip/GeoLite2-City.mmdb" && -f "$DATA_DIR/geoip/GeoLite2-ASN.mmdb" ]]; then
        log "Базы GeoIP уже на месте"
        return 0
    fi
    log "Качаю базы GeoIP (~90 МБ, это займёт минуту)"
    # Каталог передаём явно, а вывод НЕ глушим. Раньше было
    # `... >/dev/null 2>&1`, и это скрывало сразу две вещи: причину отказа и
    # то, что скрипт качал базы в другой каталог. Плюс сам скрипт всегда
    # возвращал 0, так что ветка warn была недостижима.
    if ! bash "$BOTS_DIR/telemt/scripts/update_geoip.sh" "$DATA_DIR/geoip"; then
        warn "не удалось скачать базы GeoIP — карта и определение стран работать не будут."
        warn "повторить позже: bash $BOTS_DIR/telemt/scripts/update_geoip.sh"
        return 0
    fi
    # Успех подтверждаем фактом, а не кодом возврата: это тот же критерий, по
    # которому выше решалось «базы уже на месте».
    if [[ -f "$DATA_DIR/geoip/GeoLite2-City.mmdb" && -f "$DATA_DIR/geoip/GeoLite2-ASN.mmdb" ]]; then
        log "Базы GeoIP получены"
    else
        warn "скрипт GeoIP отработал, но баз в $DATA_DIR/geoip нет — карта работать не будет."
    fi
}

# --- 5. nginx для карты ------------------------------------------------------
setup_nginx_map() {
    uses_telemt || return 0
    [[ -n "$MAP_DOMAIN" ]] || { log "Домен карты не задан — nginx не трогаю"; return 0; }
    command -v nginx >/dev/null || { warn "nginx не установлен — карту отдавать некому"; return 0; }

    # Карта содержит список ВСЕХ различных IP пользователей прокси с городом и
    # провайдером. Права каталога 750 и группа www-data вместо 755: локальным
    # пользователям её читать незачем.
    mkdir -p "$MAP_DIR"; chmod 750 "$MAP_DIR"
    chgrp www-data "$MAP_DIR" 2>/dev/null || true

    log "nginx: настраиваю отдачу карты на $MAP_DOMAIN/$MAP_PATH"
    local out
    # --mask-domain: скрипт откажется вешать карту на домен маскировки. Маска
    # копирует root панели, но не location-блоки, поэтому тот же URL на 443
    # отдавал бы 200, а через порт telemt — 404. Один запрос, и порт опознан.
    if ! out=$(python3 "$BOTS_DIR/telemt/scripts/nginx_map_location.py" \
                 --domain "$MAP_DOMAIN" --map-dir "$MAP_DIR" --path "$MAP_PATH" \
                 --mask-domain "$(conf_get_stack DOMAIN_PANEL)" 2>&1); then
        warn "не удалось изменить конфиг nginx:"
        echo "$out" | sed 's/^/       /'
        warn "подключить вручную, добавив в нужный server-блок:"
        echo "       location /$MAP_PATH/ { alias $MAP_DIR/; try_files map.html =404; }"
        return 0
    fi
    echo "$out" | sed 's/^/       /'
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx && log "nginx: конфиг применён"
    else
        warn "nginx -t не прошёл — изменения откачены, карта не подключена"
    fi
}

# --- 6. systemd --------------------------------------------------------------
write_unit() {
    local name="$1" desc="$2" script="$3"
    cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=$desc
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BOTS_DIR
ExecStart=$VENV/bin/python $BOTS_DIR/$script
Restart=always
RestartSec=10
Environment=MALLOC_TRIM_THRESHOLD_=65536

[Install]
WantedBy=multi-user.target
EOF
}

stop_unit() {
    local unit="$1"
    if systemctl list-unit-files "$unit.service" &>/dev/null && \
       [[ -f "/etc/systemd/system/$unit.service" ]]; then
        systemctl disable --now "$unit" &>/dev/null || true
        rm -f "/etc/systemd/system/$unit.service"
        log "$unit остановлен и снят (режим сменился)"
    fi
}

start_and_check() {
    local unit="$1"
    # Отметка времени берётся ДО перезапуска: иначе в проверку попадают строки
    # предыдущего процесса. Старый бот штатно падает в момент миграции данных —
    # файл базы уходит у него из-под ног, — и его трассировка выглядела бы
    # как отказ нового.
    local since; since=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl enable -q "$unit" 2>/dev/null || true
    systemctl restart "$unit"
    sleep 8
    if [[ "$(systemctl is-active "$unit")" != "active" ]]; then
        warn "$unit не запустился. Последние строки журнала:"
        journalctl -u "$unit" --since "$since" -n 15 --no-pager -o cat | sed 's/^/       /'
        return 1
    fi
    if journalctl -u "$unit" --since "$since" --no-pager -o cat 2>/dev/null \
        | grep -qE 'Traceback|ModuleNotFoundError|ValidationError|SystemExit'; then
        warn "$unit запущен, но в журнале ошибки:"
        journalctl -u "$unit" --since "$since" -n 15 --no-pager -o cat | sed 's/^/       /'
        return 1
    fi
    log "$unit: работает"
}

# ============================================================================
# ВЫПОЛНЕНИЕ
# ============================================================================
fetch_geoip
setup_nginx_map

# Режимы взаимоисключающие: снимаем то, что не нужно в выбранном режиме
if want_combined; then
    stop_unit telemt-bot
    stop_unit 3xui-monitor
    write_unit "3xui-telemt-bot" "3xui + Telemt Telegram Bot" "run_combined.py"
else
    stop_unit 3xui-telemt-bot
    if want_telemt; then
        write_unit "telemt-bot" "Telemt Telegram Bot" "run_telemt.py"
    else
        stop_unit telemt-bot
    fi
    if want_xui; then
        write_unit "3xui-monitor" "3x-ui VPN Management Telegram Bot" "run_xui.py"
    else
        stop_unit 3xui-monitor
    fi
fi

systemctl daemon-reload
echo ""
log "Запускаю службы"
FAILED=0
if want_combined; then
    start_and_check 3xui-telemt-bot || FAILED=1
else
    if want_telemt; then start_and_check telemt-bot   || FAILED=1; fi
    if want_xui;    then start_and_check 3xui-monitor || FAILED=1; fi
fi

umask 077
{
    echo "# Создан stacks/bots.sh. Права 600 — внутри токены ботов."
    echo "COMBINED_BOT_TOKEN=$COMBINED_BOT_TOKEN"
    echo "TELEMT_BOT_TOKEN=$TELEMT_BOT_TOKEN"
    echo "XUI_BOT_TOKEN=$XUI_BOT_TOKEN"
    echo "ADMIN_IDS=$ADMIN_IDS"
    echo "MAP_DOMAIN=$MAP_DOMAIN"
    printf 'MAP_PATH=%q\n' "$MAP_PATH"
    echo "BOTS_MODE=$MODE"
    # Настройки сторожа переносим сюда же: этот файл тоже создаётся заново, и
    # без записи они терялись бы при первой же переустановке режима.
    echo "WATCHDOG_ENABLED=$WATCHDOG_ENABLED"
    echo "RU_CHECK_ENABLED=$RU_CHECK_ENABLED"
    echo "RU_CHECK_INTERVAL_MINUTES=$RU_CHECK_INTERVAL_MINUTES"
    echo "RU_CHECK_PROBES=$RU_CHECK_PROBES"
    printf 'RU_CHECK_TOKEN=%q\n' "$RU_CHECK_TOKEN"
    echo "RU_CHECK_PORT=$RU_CHECK_PORT"
    echo "RU_CHECK_SNI=$RU_CHECK_SNI"
} > "$CONF"
chmod 600 "$CONF"

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo -e "\e[1;32m======================================================\e[0m"
    echo -e "\e[1;32m✅ ГОТОВО\e[0m"
    if want_combined; then echo "  3xui-telemt-bot — systemctl status 3xui-telemt-bot"; fi
    if want_telemt;   then echo "  telemt-bot      — systemctl status telemt-bot";      fi
    if want_xui;      then echo "  3xui-bot        — systemctl status 3xui-monitor";    fi
    if uses_telemt && [[ -n "$MAP_DOMAIN" ]]; then
        echo "  карта           — https://$MAP_DOMAIN/$MAP_PATH/"
    fi
    echo "  данные          — $DATA_DIR"
    echo "  настройки       — $CONF (права 600)"
    echo -e "\e[1;32m======================================================\e[0m"
else
    die "Установка завершилась с ошибками — смотри журнал выше."
fi
