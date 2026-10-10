# shellcheck shell=bash
# Защита 3x-ui-pro от чужих глаз: три правки, разбор каждой — в шапке
# tools/xui-harden.py. Коротко:
#
#   fwd     пересылка /<порт>/… только на порты своих соединений WS и gRPC
#           (было — на любой порт петли: telemt-panel и хаб beszel открывались
#           снаружи в обход секретного пути, замер 10.10.2026);
#   sni     соединение на 443 без нашего имени обрывается на рукопожатии
#           (было — получало сертификат REALITY-домена: так его и находят
#           сканеры, чтобы маскироваться им же);
#   listen  панель и подписка 3x-ui слушают только 127.0.0.1 (было — все
#           адреса, закрывал один фаервол).
#
# Все три — в реестре (lib/expectations.sh, класс fix): патч 3x-ui-pro
# переписывает includes.conf и stream.conf целиком, и правка пропала бы молча.
#
# ПОРЯДОК ПРАВКИ nginx: копия в /var/backups/vsm/nginx, подмена, nginx -t,
# reload; не собралось — возвращаем копию. Копии НЕ рядом с конфигом: nginx
# подхватывал такую копию вторым файлом и падал на дубле (30.08.2026).

XUI_HARDEN_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
XUI_HARDEN_TOOL="${XUI_HARDEN_ROOT}/tools/xui-harden.py"
XH_NGINX="${XH_NGINX:-/etc/nginx}"
XH_INCLUDES="${XH_INCLUDES:-$XH_NGINX/snippets/includes.conf}"
XH_STREAM="${XH_STREAM:-$XH_NGINX/stream-enabled/stream.conf}"
XH_REJECT_CONF="${XH_REJECT_CONF:-$XH_NGINX/conf.d/vsm-sni-reject.conf}"
XH_REJECT_PORT="${XH_REJECT_PORT:-7449}"
XH_BACKUP_DIR="${XH_BACKUP_DIR:-/var/backups/vsm/nginx}"
XH_WAIT="${XH_WAIT:-30}"

_xh()    { python3 "$XUI_HARDEN_TOOL" "$@"; }
_xh_db() { echo "${XUI_DB:-/etc/x-ui/x-ui.db}"; }
_xh_fail() { echo -e "${RED:-}❌ $*${NC:-}" >&2; return 1; }

# Подменить файлы парами «цель временный» и перезагрузить nginx. Не собрался —
# всё возвращается как было, включая удаление файлов, которых раньше не было.
_xh_nginx_swap() {
    local stamp dst src b
    local -a dsts=()
    stamp="$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$XH_BACKUP_DIR" && chmod 700 "$XH_BACKUP_DIR" || return 1
    while [ $# -ge 2 ]; do
        dst="$1"; src="$2"; shift 2
        if [ -f "$dst" ]; then
            cp -a "$dst" "$XH_BACKUP_DIR/$(basename "$dst").$stamp" || return 1
            # Права и владелец — с оригинала: подмена содержимого, не файла.
            cat "$src" > "$dst" || return 1
        else
            install -m 644 "$src" "$dst" || return 1
        fi
        dsts+=("$dst")
    done
    if nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; then
        return 0
    fi
    for dst in "${dsts[@]}"; do
        b="$XH_BACKUP_DIR/$(basename "$dst").$stamp"
        if [ -f "$b" ]; then cat "$b" > "$dst"; else rm -f "$dst"; fi
    done
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
    _xh_fail "nginx не принял правку — всё возвращено как было"
}

# --- 1. пересылка по номеру порта ------------------------------------
xui_fwd_state() {
    [ -r "$XH_INCLUDES" ] || { echo "нет файла"; return 0; }
    _xh fwd-state --file "$XH_INCLUDES"
}
xui_fwd_want() { _xh fwd-want --db "$(_xh_db)"; }
xui_fwd_apply() {
    local tmp rc
    tmp="$(mktemp)" || return 1
    if ! _xh fwd-apply --file "$XH_INCLUDES" --db "$(_xh_db)" > "$tmp"; then
        rm -f "$tmp"; _xh_fail "правило пересылки по порту не разобрать"; return 1
    fi
    if cmp -s "$tmp" "$XH_INCLUDES"; then rm -f "$tmp"; return 0; fi
    _xh_nginx_swap "$XH_INCLUDES" "$tmp"; rc=$?
    rm -f "$tmp"
    return $rc
}

# --- 2. соединения без нашего имени ----------------------------------
xui_sni_state() {
    [ -r "$XH_STREAM" ] || { echo "нет файла"; return 0; }
    local s; s="$(_xh sni-state --file "$XH_STREAM")"
    if [ "$s" = "обрыв" ] && [ ! -r "$XH_REJECT_CONF" ]; then
        s="обрыв без сервера"
    fi
    echo "$s"
}
xui_sni_want() { echo "обрыв"; }
xui_sni_apply() {
    local t1 t2 rc busy
    # Порт обрыва занят кем-то кроме nginx — молча отнимать его нельзя.
    busy="$(ss -tlnpH "sport = :$XH_REJECT_PORT" 2>/dev/null | grep -v '"nginx"')"
    if [ -n "$busy" ]; then
        _xh_fail "порт $XH_REJECT_PORT занят не nginx — задайте XH_REJECT_PORT"; return 1
    fi
    t1="$(mktemp)" && t2="$(mktemp)" || return 1
    if ! _xh sni-apply --file "$XH_STREAM" --port "$XH_REJECT_PORT" > "$t1" \
        || ! _xh sni-conf --port "$XH_REJECT_PORT" > "$t2"; then
        rm -f "$t1" "$t2"; _xh_fail "карту SNI в $XH_STREAM не разобрать"; return 1
    fi
    if cmp -s "$t1" "$XH_STREAM" && [ -r "$XH_REJECT_CONF" ] && cmp -s "$t2" "$XH_REJECT_CONF"; then
        rm -f "$t1" "$t2"; return 0
    fi
    _xh_nginx_swap "$XH_STREAM" "$t1" "$XH_REJECT_CONF" "$t2"; rc=$?
    rm -f "$t1" "$t2"
    return $rc
}

# --- 3. панель на петле ----------------------------------------------
_xh_sql() { sqlite3 -cmd ".timeout 5000" "$(_xh_db)" "$@"; }
_xh_setting_get() { _xh_sql "select value from settings where key = '$1';"; }
_xh_setting_put() {
    _xh_sql "update settings set value = '$2' where key = '$1';
             insert into settings (key, value) select '$1', '$2'
                 where not exists (select 1 from settings where key = '$1');"
}
xui_listen_state() { _xh listen-state --db "$(_xh_db)"; }
xui_listen_want()  { _xh listen-want; }

# Слушает ли порт ТОЛЬКО петлю — по факту сокета, а не по базе: панель могла
# не перечитать настройку.
_xh_loopback_only() {
    local port="$1" lines
    lines="$(ss -tlnH "sport = :$port" 2>/dev/null | awk '{print $4}')"
    [ -n "$lines" ] && ! grep -qvE '^(127\.0\.0\.1|\[::1\]):' <<< "$lines"
}

xui_listen_apply() {
    local old_web old_sub web_port sub_port i
    old_web="$(_xh_setting_get webListen)"; old_sub="$(_xh_setting_get subListen)"
    web_port="$(_xh_setting_get webPort)";  sub_port="$(_xh_setting_get subPort)"
    [ -n "$web_port" ] || { _xh_fail "порт панели в базе не найден"; return 1; }
    _xh_setting_put webListen 127.0.0.1 && _xh_setting_put subListen 127.0.0.1 || return 1
    systemctl restart x-ui >/dev/null 2>&1
    # Настройки панель читает при старте; ждём, пока поднимется уже на петле.
    for ((i = 0; i < XH_WAIT; i++)); do
        if _xh_loopback_only "$web_port" && { [ -z "$sub_port" ] || _xh_loopback_only "$sub_port"; }; then
            return 0
        fi
        sleep 1
    done
    _xh_setting_put webListen "$old_web"; _xh_setting_put subListen "$old_sub"
    systemctl restart x-ui >/dev/null 2>&1
    _xh_fail "панель не поднялась на 127.0.0.1 за ${XH_WAIT} с — настройки возвращены"
}

# Все три разом — этап установщика стека.
xui_harden_apply() {
    local rc=0
    xui_fwd_apply    || rc=1
    xui_sni_apply    || rc=1
    xui_listen_apply || rc=1
    return $rc
}
