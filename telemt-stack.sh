#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# УСТАНОВЩИК СТЕКА: 3x-ui-pro + telemt + telemt_panel
#
# Встроен в VSM (пункт "telemt / MTProto"), запускается локально.
#
# Два режима работы (--mode):
#   full  — ставит 3x-ui-pro с нуля, затем telemt и telemt_panel.
#           ВНИМАНИЕ: установщик панели стирает существующую /etc/x-ui
#           (БД, инбаунды, пользователей).
#   addon — ставит только telemt и telemt_panel поверх УЖЕ установленной
#           3x-ui-pro, ничего в панели не трогая. Режим по умолчанию.
#
# ОБЯЗАТЕЛЬНЫЕ ПЕРЕМЕННЫЕ:
#   DOMAIN_PANEL    — домен панели 3x-ui-pro, он же self-SNI цель для telemt
#   DOMAIN_REALITY  — домен REALITY SNI-роутинга, он же домен telemt_panel
#                     (обязан отличаться от DOMAIN_PANEL)
#
# ОПЦИОНАЛЬНЫЕ:
#   TELEMT_PORT=8444        публичный порт telemt
#   TELEMT_MASK_PORT=7444   локальный порт self-SNI vhost
#   PANEL_PORT=9444         публичный порт telemt_panel
#   TELEMT_SECRET=<hex32>   MTProto-секрет (по умолчанию генерируется;
#                           при повторном запуске переиспользуется старый)
#   PANEL_ADMIN_USER=admin
#   PANEL_ADMIN_PASS=<...>  (по умолчанию генерируется)
# ============================================================================

STACK_CONF_DIR="/etc/vsm"
STACK_CONF="$STACK_CONF_DIR/telemt.conf"
STACK_CREDS="$STACK_CONF_DIR/telemt-credentials.txt"

MODE="addon"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-addon}"; shift 2 ;;
        *)      shift ;;
    esac
done
case "$MODE" in full|addon) ;; *) MODE="addon" ;; esac

log()  { echo -e "\e[1;32m[этап]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m    $*"; }
die()  { echo -e "\e[1;31m[СБОЙ]\e[0m $*" >&2; exit 1; }
verify_or_die() { "$@" || die "проверка не прошла: $*"; }

# Повторяет команду раз в секунду, пока та не вернёт 0. Нужна там, где systemd
# уже отдал "active", а сама служба ещё дозапускается: фиксированный sleep либо
# тормозит установку, либо не дожидается — и то и другое мы поймали в бою.
wait_until() {
    local tries="$1"; shift
    local i
    for ((i = 1; i <= tries; i++)); do
        if "$@"; then return 0; fi
        sleep 1
    done
    return 1
}

# Ожидание освобождения блокировки dpkg. Двойник функции из
# _config_and_utils.sh: этот скрипт самодостаточен и утилиты меню не
# подключает, поэтому небольшое повторение здесь дешевле связности.
#
# Нужно потому, что стек ставят на только что созданный VPS, где первые минуты
# работает unattended-upgrades. Без ожидания apt возвращает ошибку, пакет молча
# не ставится — так на чистой Ubuntu 24.04 не установился acl.
wait_for_apt() {
    local waited=0 limit="${1:-300}"
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
                /var/lib/apt/lists/lock &>/dev/null; do
        [ "$waited" -eq 0 ] && log "жду освобождения apt (идут автообновления)..."
        sleep 3
        waited=$((waited + 3))
        # Возвращаем 0, а не 1. Прежнее "return 1" убивало установщик молча:
        # оба вызова — голые команды под set -euo pipefail, поэтому сразу после
        # слова «продолжаю» скрипт завершался, не дойдя ни до одного die. Текст
        # прямо противоречил поведению, а на вызове перед выдачей доступа к
        # сертификату это ещё и происходило до сохранения секрета в telemt.conf.
        # Дубль этой функции в bots-stack.sh с самого начала делал break, то
        # есть действительно продолжал, — приводим копии к одному поведению.
        [ "$waited" -ge "$limit" ] && { warn "apt занят дольше ${limit} с, продолжаю без ожидания."; return 0; }
    done
    return 0
}

[[ "$(id -u)" -eq 0 ]] || die "Запускай под root."

# Генератор self-SNI vhost общий с menu_telemt.sh: раньше он был двумя копиями
# одного heredoc, и одинаковый дефект пришлось бы чинить дважды. Путь считаем
# от своего расположения, а не жёстко: при запуске через симлинк из
# /usr/local/bin readlink -f приводит к реальному файлу в каталоге репозитория.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
[[ -f "$SCRIPT_DIR/_nginx_mask.sh" ]] || \
    die "Не найден $SCRIPT_DIR/_nginx_mask.sh — обнови VSM (install.sh) и повтори."
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_nginx_mask.sh"

: "${DOMAIN_PANEL:?Не задан DOMAIN_PANEL}"
: "${DOMAIN_REALITY:?Не задан DOMAIN_REALITY}"

[[ "$DOMAIN_PANEL" != "$DOMAIN_REALITY" ]] || \
    die "DOMAIN_PANEL и DOMAIN_REALITY должны быть РАЗНЫМИ поддоменами: nginx stream map строит ключи по SNI, одинаковые значения дают conflicting parameter."

TELEMT_PORT="${TELEMT_PORT:-8444}"
TELEMT_MASK_PORT="${TELEMT_MASK_PORT:-7444}"
PANEL_PORT="${PANEL_PORT:-9444}"
PANEL_ADMIN_USER="${PANEL_ADMIN_USER:-admin}"

mkdir -p "$STACK_CONF_DIR"
chmod 700 "$STACK_CONF_DIR"

# Секрет и пароль переиспользуются между запусками: перегенерация ломает
# все уже выданные клиентам ссылки.
if [[ -z "${TELEMT_SECRET:-}" ]]; then
    if [[ -f "$STACK_CONF" ]] && grep -q '^TELEMT_SECRET=' "$STACK_CONF"; then
        # shellcheck disable=SC1090
        TELEMT_SECRET="$(. "$STACK_CONF"; echo "${TELEMT_SECRET:-}")"
    fi
    TELEMT_SECRET="${TELEMT_SECRET:-$(openssl rand -hex 16)}"
fi
if [[ -z "${PANEL_ADMIN_PASS:-}" ]]; then
    if [[ -f "$STACK_CONF" ]] && grep -q '^PANEL_ADMIN_PASS=' "$STACK_CONF"; then
        # shellcheck disable=SC1090
        PANEL_ADMIN_PASS="$(. "$STACK_CONF"; echo "${PANEL_ADMIN_PASS:-}")"
    fi
    PANEL_ADMIN_PASS="${PANEL_ADMIN_PASS:-$(openssl rand -base64 20)}"
fi

# ---------------------------------------------------------------------------
# Утилита: запись ключа в конкретную секцию TOML.
# Наивная вставка "после строки tls_domain" кладёт ключ в ту секцию, где
# tls_domain фактически лежит — а это не обязательно [censorship].
# ---------------------------------------------------------------------------
toml_set_in_section() {
    local file="$1" section="$2" key="$3" value="$4"

    if ! grep -q "^\[${section}\]" "$file"; then
        printf '\n[%s]\n%s = %s\n' "$section" "$key" "$value" >> "$file"
        return
    fi

    if awk -v s="[$section]" -v k="$key" '
        $0==s {ins=1; next}
        /^\[/ {ins=0}
        ins && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {found=1}
        END {exit !found}
    ' "$file"; then
        awk -v s="[$section]" -v k="$key" -v v="$value" '
            $0==s {print; ins=1; next}
            /^\[/ {ins=0}
            ins && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print k" = "v; next}
            {print}
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        awk -v s="[$section]" -v k="$key" -v v="$value" '
            $0==s {print; print k" = "v; next}
            {print}
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# ---------------------------------------------------------------------------
# ЭТАП 0 — предварительные проверки
# ---------------------------------------------------------------------------
log "Этап 0: предварительные проверки (режим: $MODE)"

if ! command -v dig >/dev/null 2>&1; then
    log "  ставлю dnsutils (нужен dig для проверки DNS)..."
    wait_for_apt
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils >/dev/null 2>&1 || \
        die "Не удалось установить dig (пакет dnsutils/bind9-dnsutils)."
fi
command -v openssl >/dev/null 2>&1 || die "Нужен openssl."

for d in "$DOMAIN_PANEL" "$DOMAIN_REALITY"; do
    ip="$(dig +short "$d" | tail -1)"
    [[ -n "$ip" ]] || die "Домен $d не резолвится. Настрой DNS (A-запись на IP этого сервера) и повтори."
    log "  $d -> $ip"
done

busy="$(ss -tulnp 2>/dev/null | grep -E ":(${TELEMT_PORT}|${PANEL_PORT}|${TELEMT_MASK_PORT}) " || true)"
if [[ -n "$busy" ]]; then
    warn "Порты стека уже кем-то заняты:"
    echo "$busy"
    warn "Продолжаю, но при конфликте сверь вручную."
fi

if [[ "$MODE" == "addon" ]]; then
    [[ -d /etc/x-ui ]] || die "3x-ui-pro не установлена (/etc/x-ui не найден). Поставь панель через пункт меню 'Управление X-UI', затем повтори."
    systemctl is-active --quiet nginx || die "nginx не запущен — self-SNI маскировке нужен рабочий backend."
fi

apt-get update -qq

# ---------------------------------------------------------------------------
# ЭТАП 1 — 3x-ui-pro (только в режиме full)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "full" ]]; then
    log "Этап 1: установка 3x-ui-pro"
    cd /root
    wget -qO x-ui-latest.sh https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh
    chmod +x x-ui-latest.sh
    bash x-ui-latest.sh \
        -install y \
        -subdomain "$DOMAIN_PANEL" \
        -reality_domain "$DOMAIN_REALITY" \
        -auto_domain n
else
    log "Этап 1: пропущен (режим addon, панель уже установлена)"
fi

verify_or_die nginx -t
verify_or_die systemctl is-active --quiet nginx
verify_or_die systemctl is-active --quiet x-ui

PANEL_WEBPATH="$(/usr/local/x-ui/x-ui setting -show true 2>&1 | grep -oP 'webBasePath:\s*\K\S+' || true)"

# Приводим к виду /путь/ ПРЯМО ЗДЕСЬ, а не в местах вывода. Панель отдаёт путь
# и без крайних слэшей, а ниже к нему дописывается panel/: из "/abc" вышло бы
# склеенное "/abcpanel/" — адрес выглядит достоверно и ведёт в 404. Ту же
# нормализацию делает xui_panel_url в _config_and_utils.sh.
#
# Полная форма if/fi, а не "[[ ... ]] && присваивание": под set -e ложное
# условие в таком виде возвращает 1 и роняет установщик молча — ровно тот
# класс дефекта, что уже дважды ловили в этом файле.
if [[ -n "$PANEL_WEBPATH" ]]; then
    if [[ "${PANEL_WEBPATH#/}" == "$PANEL_WEBPATH" ]]; then
        PANEL_WEBPATH="/$PANEL_WEBPATH"
    fi
    if [[ "${PANEL_WEBPATH%/}" == "$PANEL_WEBPATH" ]]; then
        PANEL_WEBPATH="$PANEL_WEBPATH/"
    fi
fi

# ---------------------------------------------------------------------------
# ЭТАП 2 — self-SNI vhost для telemt (БЕЗ proxy_protocol)
# ---------------------------------------------------------------------------
log "Этап 2: nginx vhost для self-SNI маскировки (127.0.0.1:${TELEMT_MASK_PORT})"

# nginx.conf обязан подключать conf.d — иначе наш файл не прочитается.
if ! grep -qE '^\s*include\s+/etc/nginx/conf\.d/\*\.conf;' /etc/nginx/nginx.conf; then
    warn "nginx.conf не подключает conf.d — добавляю include."
    sed -i '0,/^http\s*{/s//http {\n    include \/etc\/nginx\/conf.d\/*.conf;/' /etc/nginx/nginx.conf
fi

# Сборка, проверка и откат при неудаче — в _nginx_mask.sh. Откат тут не
# роскошь: битый файл в conf.d не даёт nginx стартовать вообще, и упасть,
# оставив его на диске, значит уронить панель при ближайшем рестарте.
nginx_mask_apply "$DOMAIN_PANEL" "$TELEMT_MASK_PORT" || \
    die "Не удалось установить vhost self-SNI маскировки (см. сообщение выше)."

# Та же гонка, что у telemt и панели ниже: systemctl reload возвращается по
# факту доставки сигнала, а слушателя на маскировочном порту nginx поднимает
# чуть позже. Проверка без ожидания успевала раньше и получала «соединение
# отклонено» — на установке с нуля это обрывало весь стек на этапе 2.
#
# Второе: curl тут в подстановке команды, а в файле set -e. Ненулевой код
# curl ронял скрипт РАНЬШЕ строки с die, поэтому обрыв выглядел как молчание —
# ни причины, ни этапа. Отсюда "|| true", как уже сделано для панели.
mask_responds() {
    local code
    code="$(curl -sk --max-time 5 --resolve "${DOMAIN_PANEL}:${TELEMT_MASK_PORT}:127.0.0.1" \
        "https://${DOMAIN_PANEL}:${TELEMT_MASK_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null)" || return 1
    [[ "$code" == "200" ]]
}
if ! wait_until 30 mask_responds; then
    MASK_CODE="$(curl -sk --max-time 5 --resolve "${DOMAIN_PANEL}:${TELEMT_MASK_PORT}:127.0.0.1" \
        "https://${DOMAIN_PANEL}:${TELEMT_MASK_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null)" || MASK_CODE=000
    die "self-SNI vhost вернул $MASK_CODE вместо 200 (ждали 30 с)."
fi
log "self-SNI vhost отвечает 200."

# ---------------------------------------------------------------------------
# ЭТАП 3 — telemt
# ---------------------------------------------------------------------------
log "Этап 3: установка telemt (порт ${TELEMT_PORT})"

curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- \
    -d "$DOMAIN_PANEL" -p "$TELEMT_PORT" -s "$TELEMT_SECRET" -l en

mkdir -p /etc/systemd/system/telemt.service.d
cat > /etc/systemd/system/telemt.service.d/nginx-dependency.conf << 'EOF'
[Unit]
After=network-online.target nginx.service
Requires=nginx.service
EOF

TOML=/etc/telemt/telemt.toml
[[ -f "$TOML" ]] || die "telemt не создал $TOML."
toml_set_in_section "$TOML" censorship mask true
toml_set_in_section "$TOML" censorship mask_host '"127.0.0.1"'
toml_set_in_section "$TOML" censorship mask_port "$TELEMT_MASK_PORT"

systemctl daemon-reload
systemctl restart telemt
verify_or_die systemctl is-active --quiet telemt

command -v ufw >/dev/null 2>&1 && ufw allow "${TELEMT_PORT}/tcp" >/dev/null 2>&1 || true

# Ждём готовности, а не спим фиксированно: systemd считает юнит активным сразу,
# а telemt после этого ещё поднимает пул middle-proxy — на живом сервере это
# заняло дольше двух секунд, и установка падала на Этапе 3 при полностью
# исправном сервисе, так и не добравшись до telemt_panel.
log "жду готовности telemt..."
if ! wait_until 30 curl -sf "http://127.0.0.1:9091/v1/users" -o /dev/null; then
    die "API telemt (127.0.0.1:9091) не отвечает 30 секунд. Смотри: journalctl -u telemt -n 50"
fi

# Присваивание с "|| echo 000" внутри подстановки склеивало вывод curl с эхом и
# давало "000000" вместо кода ответа. Код перезаписываем целиком.
E2E="$(curl -sk --max-time 10 "https://127.0.0.1:${TELEMT_PORT}/" -o /dev/null -w '%{http_code}')" || E2E=000
if [[ "$E2E" == "200" ]]; then
    log "Сквозной self-SNI тест через telemt: 200."
else
    warn "Сквозной self-SNI тест вернул $E2E вместо 200 — маскировка может не работать."
    warn "Проверь вручную: curl -skv https://127.0.0.1:${TELEMT_PORT}/ и journalctl -u telemt -n 50"
fi

log "telemt установлен и проверен."

# ---------------------------------------------------------------------------
# ЭТАП 4 — telemt_panel
# ---------------------------------------------------------------------------
log "Этап 4: установка telemt_panel (порт ${PANEL_PORT})"

# Установщик интерактивен, и ответы ему нельзя подать ни через "curl | bash"
# (там stdin занят текстом самого скрипта), ни просто через stdin: свои вопросы
# он читает из /dev/tty напрямую — "read -r _val < /dev/tty". Пайп на stdin он
# попросту игнорирует, а без управляющего терминала (запуск из systemd, по cron
# или отсоединённым сеансом) падает с "/dev/tty: No such device or address" и
# "_val: unbound variable". Поэтому скачиваем установщик в файл и запускаем под
# псевдотерминалом script(1): /dev/tty у него появляется, а ответы приходят
# туда же со стандартного ввода.
command -v script >/dev/null 2>&1 || \
    die "Нужен script(1) из util-linux — через него установщику telemt_panel выдаётся псевдотерминал."
PANEL_INSTALLER="$(mktemp /tmp/telemt-panel-install.XXXXXX.sh)"
trap 'rm -f "$PANEL_INSTALLER"' EXIT
curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh -o "$PANEL_INSTALLER"
[[ -s "$PANEL_INSTALLER" ]] || die "Не удалось скачать установщик telemt_panel."

# Порядок вопросов: API URL, auth header, admin user, admin password,
# путь к бинарнику telemt, имя systemd-юнита. Пустая строка = дефолт.
#
# "stty -echo" плюс пауза перед подачей ответов — против утечки пароля. Строчная
# дисциплина псевдотерминала отражает всё поданное на вход СРАЗУ по приходу,
# задолго до того, как установщик доберётся до своего prompt_secret и сам
# погасит эхо; без этого пароль админа уходит в stdout открытым текстом и
# оседает в любом логе, куда перенаправлен вывод. Пауза нужна, чтобы stty успел
# отработать раньше, чем script нальёт ответы в терминал. Если паузы всё же не
# хватит, установка не сломается — вернётся прежнее поведение с эхом.
{ sleep 2; printf '\n\n%s\n%s\n\n\n' "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS"; } \
    | script -qe -c "stty -echo 2>/dev/null; bash '$PANEL_INSTALLER'" /dev/null

PANEL_TOML=/etc/telemt-panel/config.toml
[[ -f "$PANEL_TOML" ]] || die "telemt_panel не создал $PANEL_TOML."

sed -i "s|^listen = .*|listen = \"0.0.0.0:${PANEL_PORT}\"|" "$PANEL_TOML"
if ! grep -q '^\[tls\]' "$PANEL_TOML"; then
    cat >> "$PANEL_TOML" << EOF

[tls]
cert_file = "/etc/letsencrypt/live/${DOMAIN_REALITY}/fullchain.pem"
key_file  = "/etc/letsencrypt/live/${DOMAIN_REALITY}/privkey.pem"
EOF
fi

# Доступ панели строго к своему сертификату, а не ко всему /etc/letsencrypt:
# панель смотрит наружу, и приватные ключи остальных доменов ей не нужны.
#
# Раньше здесь установка acl шла с заглушённым выводом, а следом сразу setfacl.
# На свежей Ubuntu блокировку dpkg держит unattended-upgrades, acl не ставился,
# setfacl не находился, и весь установщик умирал на коде 127 — без сообщения,
# с панелью в вечном цикле перезапуска и без сохранённых учётных данных.
if id telemt-panel &>/dev/null; then
    REAL_DIR="$(readlink -f "/etc/letsencrypt/live/${DOMAIN_REALITY}/privkey.pem" | xargs dirname)"

    if ! command -v setfacl >/dev/null 2>&1; then
        wait_for_apt
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq acl >/dev/null 2>&1 || true
    fi

    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:telemt-panel:x /etc/letsencrypt/live /etc/letsencrypt/archive
        setfacl -m u:telemt-panel:rx "/etc/letsencrypt/live/${DOMAIN_REALITY}"
        setfacl -R -m u:telemt-panel:rX "$REAL_DIR"
        setfacl -d -m u:telemt-panel:rX "$REAL_DIR"
    else
        # Запасной путь вместо смерти: доступ через группу панели. Шире, чем
        # ACL (группа получает право войти в каталоги live и archive), но
        # ключи остальных доменов по-прежнему закрыты правами самих файлов,
        # а панель работает — это лучше, чем бесконечный перезапуск.
        warn "setfacl недоступен — выдаю доступ к сертификату через группу telemt-panel."
        chgrp telemt-panel /etc/letsencrypt/live /etc/letsencrypt/archive
        chmod g+x /etc/letsencrypt/live /etc/letsencrypt/archive
        chgrp -R telemt-panel "/etc/letsencrypt/live/${DOMAIN_REALITY}" "$REAL_DIR"
        chmod -R g+rX "/etc/letsencrypt/live/${DOMAIN_REALITY}" "$REAL_DIR"
    fi
else
    warn "Пользователь telemt-panel не найден — доступ к сертификату не выдан."
fi

systemctl restart telemt-panel
verify_or_die systemctl is-active --quiet telemt-panel

command -v ufw >/dev/null 2>&1 && ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true

# Та же гонка, что и у telemt: ждём готовности, а не спим наугад.
if ! wait_until 20 curl -sk --max-time 5 "https://127.0.0.1:${PANEL_PORT}/" -o /dev/null; then
    warn "telemt_panel не отвечает на https://127.0.0.1:${PANEL_PORT}/ — смотри journalctl -u telemt-panel"
fi
PCODE="$(curl -sk --max-time 10 "https://127.0.0.1:${PANEL_PORT}/" -o /dev/null -w '%{http_code}')" || PCODE=000
[[ "$PCODE" == "200" ]] || warn "telemt_panel вернул $PCODE вместо 200 — смотри journalctl -u telemt-panel"

# ---------------------------------------------------------------------------
# СОХРАНЕНИЕ СОСТОЯНИЯ
# ---------------------------------------------------------------------------
# printf %q — значения переживают повторный source без риска инъекции.
{
    echo "# Создано telemt-stack.sh, не редактируй вручную."
    printf 'DOMAIN_PANEL=%q\n'     "$DOMAIN_PANEL"
    printf 'DOMAIN_REALITY=%q\n'   "$DOMAIN_REALITY"
    printf 'TELEMT_PORT=%q\n'      "$TELEMT_PORT"
    printf 'TELEMT_MASK_PORT=%q\n' "$TELEMT_MASK_PORT"
    printf 'PANEL_PORT=%q\n'       "$PANEL_PORT"
    printf 'TELEMT_SECRET=%q\n'    "$TELEMT_SECRET"
    printf 'PANEL_ADMIN_USER=%q\n' "$PANEL_ADMIN_USER"
    printf 'PANEL_ADMIN_PASS=%q\n' "$PANEL_ADMIN_PASS"
} > "$STACK_CONF"
chmod 600 "$STACK_CONF"

{
    echo "Стек telemt — учётные данные (создано $(date '+%Y-%m-%d %H:%M:%S'))"
    # Адрес в длинной форме, с panel/ на конце: это и есть форма входа, и ровно
    # так его собирает xui_panel_url для шапок меню. Короткая форма работала,
    # но расходилась с шапками, и было не понять, какая из двух правильная.
    echo "Панель 3x-ui-pro:   https://${DOMAIN_PANEL}${PANEL_WEBPATH:-/}panel/"
    echo "telemt порт:        ${TELEMT_PORT}"
    echo "telemt secret:      ${TELEMT_SECRET}"
    echo "telemt_panel:       https://${DOMAIN_REALITY}:${PANEL_PORT}"
    echo "telemt_panel логин: ${PANEL_ADMIN_USER}"
    echo "telemt_panel пароль: ${PANEL_ADMIN_PASS}"
} > "$STACK_CREDS"
chmod 600 "$STACK_CREDS"

cat << SUMMARY

════════════════════════════════════════════════════════════════
УСТАНОВКА ЗАВЕРШЕНА (режим: ${MODE})

  Панель 3x-ui-pro:    https://${DOMAIN_PANEL}${PANEL_WEBPATH:-/<путь из вывода установщика>/}panel/
  REALITY SNI-ключ:    ${DOMAIN_REALITY}
  telemt порт:         ${TELEMT_PORT}  (self-SNI цель: ${DOMAIN_PANEL})
  telemt_panel:        https://${DOMAIN_REALITY}:${PANEL_PORT}
  Логин панели telemt: ${PANEL_ADMIN_USER}

  Секрет и пароль НЕ печатаются здесь намеренно — они сохранены в
  ${STACK_CREDS} (права 600).
  Посмотреть: пункт меню "Показать учётные данные".

ДАЛЬШЕ:
  • SYN FIX (MEKO) — отдельный пункт меню.
  • Постквантовый TLS — пункт "Пересборка nginx с OpenSSL 3.5".
  • После любого патча/переустановки 3x-ui-pro прогони пункт
    "Статус и диагностика" — он проверит, жива ли маскировка.
════════════════════════════════════════════════════════════════
SUMMARY
