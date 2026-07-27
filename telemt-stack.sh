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

# self-SNI vhost лежит в conf.d, а НЕ в sites-enabled: установщик и патч
# 3x-ui-pro очищают sites-enabled целиком (rm -rf / find -delete), и файл
# в sites-enabled молча исчезал бы вместе с маскировкой.
MASK_VHOST="/etc/nginx/conf.d/telemt-mask.conf"

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

[[ "$(id -u)" -eq 0 ]] || die "Запускай под root."

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

# ---------------------------------------------------------------------------
# ЭТАП 2 — self-SNI vhost для telemt (БЕЗ proxy_protocol)
# ---------------------------------------------------------------------------
log "Этап 2: nginx vhost для self-SNI маскировки (127.0.0.1:${TELEMT_MASK_PORT})"

SRC_VHOST="/etc/nginx/sites-available/${DOMAIN_PANEL}"
[[ -f "$SRC_VHOST" ]] || SRC_VHOST="/etc/nginx/sites-enabled/${DOMAIN_PANEL}"
[[ -f "$SRC_VHOST" ]] || die "Не найден vhost домена $DOMAIN_PANEL — проверь, что 3x-ui-pro установлена именно на этот домен."

WEBROOT="$(grep -oP '^\s*root\s+\K[^;]+' "$SRC_VHOST" | head -1)"
CERT_FILE="$(grep -oP 'ssl_certificate\s+\K[^;]+' "$SRC_VHOST" | head -1)"
CERT_KEY="$(grep -oP 'ssl_certificate_key\s+\K[^;]+' "$SRC_VHOST" | head -1)"
[[ -n "$WEBROOT" && -n "$CERT_FILE" && -n "$CERT_KEY" ]] || \
    die "Не удалось извлечь root/ssl_certificate из $SRC_VHOST."

# nginx.conf обязан подключать conf.d — иначе наш файл не прочитается.
if ! grep -qE '^\s*include\s+/etc/nginx/conf\.d/\*\.conf;' /etc/nginx/nginx.conf; then
    warn "nginx.conf не подключает conf.d — добавляю include."
    sed -i '0,/^http\s*{/s//http {\n    include \/etc\/nginx\/conf.d\/*.conf;/' /etc/nginx/nginx.conf
fi

mkdir -p /etc/nginx/conf.d
cat > "$MASK_VHOST" << EOF
# self-SNI цель для telemt. Лежит в conf.d намеренно: установщик и патч
# 3x-ui-pro очищают sites-enabled целиком, и здесь файл это переживает.
# БЕЗ proxy_protocol: telemt при сплайсинге заголовок не добавляет,
# поэтому направить маскировку на штатный 7443 нельзя.
server {
    listen 127.0.0.1:${TELEMT_MASK_PORT} ssl;
    http2 on;

    server_name ${DOMAIN_PANEL};
    root ${WEBROOT};

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${CERT_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;

    index index.html index.htm index.php;
}
EOF

verify_or_die nginx -t
systemctl reload nginx

MASK_CODE="$(curl -sk --resolve "${DOMAIN_PANEL}:${TELEMT_MASK_PORT}:127.0.0.1" \
    "https://${DOMAIN_PANEL}:${TELEMT_MASK_PORT}/" -o /dev/null -w '%{http_code}')"
[[ "$MASK_CODE" == "200" ]] || die "self-SNI vhost вернул $MASK_CODE вместо 200."
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

sleep 2
E2E="$(curl -sk "https://127.0.0.1:${TELEMT_PORT}/" -o /dev/null -w '%{http_code}' || echo 000)"
if [[ "$E2E" == "200" ]]; then
    log "Сквозной self-SNI тест через telemt: 200."
else
    warn "Сквозной self-SNI тест вернул $E2E вместо 200 — маскировка может не работать."
    warn "Проверь вручную: curl -skv https://127.0.0.1:${TELEMT_PORT}/ и journalctl -u telemt -n 50"
fi

verify_or_die curl -sf "http://127.0.0.1:9091/v1/users" -o /dev/null
log "telemt установлен и проверен."

# ---------------------------------------------------------------------------
# ЭТАП 4 — telemt_panel
# ---------------------------------------------------------------------------
log "Этап 4: установка telemt_panel (порт ${PANEL_PORT})"

# Установщик интерактивен. Скачиваем его в файл и только потом подаём
# ответы на stdin: при "curl | bash" stdin занят самим текстом скрипта,
# и read вычитывает исходный код вместо ответов.
PANEL_INSTALLER="$(mktemp /tmp/telemt-panel-install.XXXXXX.sh)"
trap 'rm -f "$PANEL_INSTALLER"' EXIT
curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh -o "$PANEL_INSTALLER"
[[ -s "$PANEL_INSTALLER" ]] || die "Не удалось скачать установщик telemt_panel."

# Порядок вопросов: API URL, auth header, admin user, admin password,
# путь к бинарнику telemt, имя systemd-юнита. Пустая строка = дефолт.
printf '\n\n%s\n%s\n\n\n' "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS" | bash "$PANEL_INSTALLER"

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

# ACL строго на свой сертификат, а не на весь /etc/letsencrypt: панель
# смотрит наружу, и доступ ко всем приватным ключам сервера ей не нужен.
if id telemt-panel &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq acl >/dev/null 2>&1
    REAL_DIR="$(readlink -f "/etc/letsencrypt/live/${DOMAIN_REALITY}/privkey.pem" | xargs dirname)"
    setfacl -m u:telemt-panel:x /etc/letsencrypt/live /etc/letsencrypt/archive
    setfacl -m u:telemt-panel:rx "/etc/letsencrypt/live/${DOMAIN_REALITY}"
    setfacl -R -m u:telemt-panel:rX "$REAL_DIR"
    setfacl -d -m u:telemt-panel:rX "$REAL_DIR"
else
    warn "Пользователь telemt-panel не найден — ACL на сертификат не выставлен."
fi

systemctl restart telemt-panel
verify_or_die systemctl is-active --quiet telemt-panel

command -v ufw >/dev/null 2>&1 && ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true

sleep 2
PCODE="$(curl -sk "https://127.0.0.1:${PANEL_PORT}/" -o /dev/null -w '%{http_code}' || echo 000)"
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
    echo "Панель 3x-ui-pro:   https://${DOMAIN_PANEL}${PANEL_WEBPATH:-/}"
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

  Панель 3x-ui-pro:    https://${DOMAIN_PANEL}${PANEL_WEBPATH:-/<путь из вывода установщика>}
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
