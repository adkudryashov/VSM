# shellcheck shell=bash
# Сайт-заглушка VSM вместо шаблона 3x-ui-pro.
#
# 3x-ui-pro кладёт в /var/www/html один из десяти общедоступных шаблонов,
# одинаковых у всех установок: по странице сервер узнают (10.10.2026). Эту же
# страницу видят все, кто приходит на наши домены не за подключением: сайт на
# 443, маска telemt на 8444, приманка WEB Proxy. Свой сайт собирает
# tools/stub-site.py — шведский футбольный клуб, название из домена, остальное
# из случайного числа сервера.
#
# Состояние — /etc/vsm/stub-site.conf: число (STUB_SEED, чтобы сайт не менялся
# от сборки к сборке) и отпечаток index.html (STUB_SHA — по нему сверка
# реестра отличает наш сайт от вернувшегося шаблона). Список наших файлов —
# /etc/vsm/stub-site.files: при обновлении убираем только своё.
#
# Прежнюю страницу перед первой заменой упаковываем в /var/backups/vsm/www:
# вернуть её можно пунктом меню. .well-known не трогаем никогда — через него
# certbot продлевает сертификат (lib/cert_renew.sh).

STUB_SITE_ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STUB_TOOL="${STUB_SITE_ROOT_DIR}/tools/stub-site.py"
STUB_ROOT="${STUB_ROOT:-/var/www/html}"
STUB_CONF="${STUB_CONF:-/etc/vsm/stub-site.conf}"
STUB_FILES="${STUB_FILES:-/etc/vsm/stub-site.files}"
STUB_BACKUP_DIR="${STUB_BACKUP_DIR:-/var/backups/vsm/www}"
STUB_STACK_CONF="${STUB_STACK_CONF:-/etc/vsm/telemt.conf}"
STUB_SYSTEMD="${STUB_SYSTEMD:-/etc/systemd/system}"

_stub_fail() { echo -e "${RED:-}❌ $*${NC:-}" >&2; return 1; }

_stub_get() {
    [ -r "$STUB_CONF" ] || return 0
    grep -m1 -oP "^$1=\\K.*" "$STUB_CONF" 2>/dev/null | tr -d "'\""
}

# STUB_DOMAIN — для установщика стека: он ставит сайт раньше, чем записывает
# свой конфиг.
stub_site_domain() {
    if [ -n "${STUB_DOMAIN:-}" ]; then echo "$STUB_DOMAIN"; return 0; fi
    [ -r "$STUB_STACK_CONF" ] || return 0
    grep -m1 -oP '^DOMAIN_PANEL=\K.*' "$STUB_STACK_CONF" 2>/dev/null | tr -d "'\""
}

_stub_sha() { [ -f "$STUB_ROOT/index.html" ] && sha256sum "$STUB_ROOT/index.html" | cut -c1-64; }

# Что сейчас отдаёт webroot: «наш сайт», «чужая страница» или «нет страницы».
stub_site_state() {
    local sha want
    sha="$(_stub_sha)"
    [ -n "$sha" ] || { echo "нет страницы"; return 0; }
    want="$(_stub_get STUB_SHA)"
    if [ -n "$want" ] && [ "$sha" = "$want" ]; then echo "наш сайт"; else echo "чужая страница"; fi
}

stub_site_name() {
    local seed domain
    seed="$(_stub_get STUB_SEED)"; domain="$(stub_site_domain)"
    [ -n "$seed" ] && [ -n "$domain" ] || return 0
    python3 "$STUB_TOOL" name --domain "$domain" --seed "$seed" 2>/dev/null
}

_stub_new_seed() { od -An -N4 -tu4 /dev/urandom | tr -dc '0-9'; }

_stub_save_conf() {
    mkdir -p "$(dirname "$STUB_CONF")" || return 1
    printf 'STUB_SEED=%s\nSTUB_SHA=%s\n' "$1" "$2" > "$STUB_CONF.tmp" &&
        chmod 600 "$STUB_CONF.tmp" && mv -f "$STUB_CONF.tmp" "$STUB_CONF"
}

# Всё в корне сайта, кроме .well-known. -print0 и find -delete не годятся:
# каталоги шаблона непустые, а rm -rf по списку проще проверить глазами.
_stub_clear_root() {
    [ -d "${STUB_ROOT:?}" ] && [ "$STUB_ROOT" != "/" ] || return 1
    find "$STUB_ROOT" -mindepth 1 -maxdepth 1 ! -name .well-known -exec rm -rf -- {} +
}

# Упаковать то, что лежит в корне сайта сейчас (кроме .well-known).
_stub_backup() {
    local stamp out
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$STUB_BACKUP_DIR" && chmod 700 "$STUB_BACKUP_DIR" || return 1
    out="$STUB_BACKUP_DIR/webroot-$stamp.tar.gz"
    tar -C "$STUB_ROOT" --exclude=./.well-known -czf "$out" . || { rm -f "$out"; return 1; }
    echo "$out"
}

# Собрать и выложить. $1 — «new», чтобы взять новое случайное число (другие
# цвета, герб, состав; название из домена остаётся).
stub_site_apply() {
    local domain seed tmp owner state f
    domain="$(stub_site_domain)"
    [ -n "$domain" ] || { _stub_fail "домен панели не найден в $STUB_STACK_CONF — стек telemt установлен?"; return 1; }
    command -v python3 >/dev/null 2>&1 || { _stub_fail "нужен python3"; return 1; }
    mkdir -p "$STUB_ROOT" || return 1
    seed="$(_stub_get STUB_SEED)"
    if [ "${1:-}" = new ] || [ -z "$seed" ]; then seed="$(_stub_new_seed)"; fi
    [ -n "$seed" ] || { _stub_fail "не получилось случайное число"; return 1; }

    tmp="$(mktemp -d)" || return 1
    if ! python3 "$STUB_TOOL" build --out "$tmp/site" --domain "$domain" --seed "$seed" > "$tmp/files"; then
        rm -rf -- "$tmp"; _stub_fail "сайт не собрался"; return 1
    fi

    state="$(stub_site_state)"
    if [ "$state" = "наш сайт" ] && [ -r "$STUB_FILES" ]; then
        # Своё убираем по списку: вдруг рядом лежит то, что положил владелец.
        while IFS= read -r f; do
            case "$f" in ''|/*|*..*) continue ;; esac
            rm -f -- "$STUB_ROOT/$f"
        done < "$STUB_FILES"
        find "$STUB_ROOT" -mindepth 1 -type d -empty ! -path "$STUB_ROOT/.well-known*" -delete 2>/dev/null
    elif [ -n "$(find "$STUB_ROOT" -mindepth 1 -maxdepth 1 ! -name .well-known -print -quit)" ]; then
        if ! _stub_backup >/dev/null; then
            rm -rf -- "$tmp"; _stub_fail "не удалось сохранить прежнюю страницу — ничего не тронуто"; return 1
        fi
        _stub_clear_root || { rm -rf -- "$tmp"; _stub_fail "не удалось очистить $STUB_ROOT"; return 1; }
    fi

    owner="$(stat -c %U:%G "$STUB_ROOT")"
    cp -r "$tmp/site/." "$STUB_ROOT/" || { rm -rf -- "$tmp"; _stub_fail "не удалось выложить сайт"; return 1; }
    while IFS= read -r f; do
        chown "$owner" "$STUB_ROOT/$f" 2>/dev/null
        chmod 644 "$STUB_ROOT/$f"
    done < "$tmp/files"
    find "$STUB_ROOT" -mindepth 1 -type d ! -path "$STUB_ROOT/.well-known*" -exec chmod 755 {} + -exec chown "$owner" {} + 2>/dev/null
    mkdir -p "$(dirname "$STUB_FILES")" && cp "$tmp/files" "$STUB_FILES"
    rm -rf -- "$tmp"
    _stub_save_conf "$seed" "$(_stub_sha)" || return 1
    stub_site_timer_install
}

# Раз в неделю пересобираем с тем же числом: сыгранные матчи получают счёт,
# выходят новые заметки. Только если стоит наш сайт — вернувшийся шаблон
# возвращает сверка реестра, и она же об этом говорит.
stub_site_refresh() {
    [ -r "$STUB_CONF" ] || return 0
    [ "$(stub_site_state)" = "наш сайт" ] || return 0
    stub_site_apply
}

stub_site_timer_install() {
    command -v systemctl >/dev/null 2>&1 || return 0
    cat > "$STUB_SYSTEMD/vsm-stub-site.service" <<EOF
[Unit]
Description=VSM: обновить сайт-заглушку (календарь и новости)

[Service]
Type=oneshot
ExecStart=/bin/bash $STUB_SITE_ROOT_DIR/tools/stub-site.sh refresh
NoNewPrivileges=yes
PrivateTmp=yes
EOF
    cat > "$STUB_SYSTEMD/vsm-stub-site.timer" <<'EOF'
[Unit]
Description=VSM: сайт-заглушка раз в неделю

[Timer]
OnCalendar=weekly
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable -q --now vsm-stub-site.timer >/dev/null 2>&1 || true
}

# Вернуть страницу, которая стояла до нас: последнюю копию из $STUB_BACKUP_DIR.
stub_site_restore() {
    local last
    last="$(ls -1t "$STUB_BACKUP_DIR"/webroot-*.tar.gz 2>/dev/null | head -1)"
    [ -n "$last" ] || { _stub_fail "копии прежней страницы нет в $STUB_BACKUP_DIR"; return 1; }
    _stub_clear_root || return 1
    tar -C "$STUB_ROOT" -xzf "$last" || { _stub_fail "не удалось распаковать $last"; return 1; }
    rm -f "$STUB_CONF" "$STUB_FILES"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable -q --now vsm-stub-site.timer >/dev/null 2>&1
        rm -f "$STUB_SYSTEMD/vsm-stub-site.timer" "$STUB_SYSTEMD/vsm-stub-site.service"
        systemctl daemon-reload >/dev/null 2>&1
    fi
    echo "$last"
}
