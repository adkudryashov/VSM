# shellcheck shell=bash
# Хаб beszel на этом сервере: поставить, завести учётную запись владельца,
# выпустить наружу через nginx по TLS.
#
# ЗАЧЕМ В VSM. Хаб на 179.254.109.140 ставился руками по частям: официальный
# установщик, перевод на петлю отдельным drop-in, конфиг nginx, порт в ufw.
# Сервер переустановили — и всё это ушло вместе с ним, повторить было нечем.
#
# СТАВИТ ОФИЦИАЛЬНЫЙ УСТАНОВЩИК (supplemental/scripts/install-hub.sh): бинарь,
# пользователь beszel, служба beszel-hub, суточный таймер обновления. Свой не
# пишем — разошёлся бы с авторским. Ключи прочитаны 25.09.2026: -p, --auto-update,
# -u; вопросов установщик не задаёт.
#
# ПЕТЛЯ С ПЕРВОЙ СЕКУНДЫ. Установщик сам запускает хаб на 0.0.0.0:8090. Drop-in
# с петлёй кладётся ДО его запуска: daemon-reload установщика подхватывает его,
# и хаб ни разу не слушает внешний адрес. Это важно не только ради порта.
#
# УЧЁТНАЯ ЗАПИСЬ — ДО ВЫХОДА НАРУЖУ. Свежий хаб отдаёт /api/beszel/create-user
# без авторизации: первый, кто откроет страницу, становится администратором
# (internal/users/users.go, CreateFirstUser). Выпусти мы хаб в nginx раньше —
# хаб достался бы тому, кто успел первым. Поэтому VSM сам зовёт create-user
# через петлю, проверяет, что first-run погас, и только потом пишет nginx.
# Пароль идёт в curl через stdin, не аргументом: аргументы видны в ps.
#
# НАРУЖУ — ОТДЕЛЬНЫЙ ФАЙЛ В conf.d, а не в sites-enabled: тот каталог патч
# 3x-ui-pro чистит целиком. Обращение без нашего имени отвергается ещё на
# рукопожатии TLS (ssl_reject_handshake) — хаб не откликается сканерам по IP.

BESZEL_HUB_INSTALLER_URL="${BESZEL_HUB_INSTALLER_URL:-https://raw.githubusercontent.com/henrygd/beszel/main/supplemental/scripts/install-hub.sh}"
BESZEL_HUB_BIN="${BESZEL_HUB_BIN:-/opt/beszel/beszel}"
BESZEL_HUB_DROPIN="${BESZEL_HUB_DROPIN:-/etc/systemd/system/beszel-hub.service.d/10-vsm-loopback.conf}"
BESZEL_HUB_LOCAL="${BESZEL_HUB_LOCAL:-127.0.0.1:8090}"
BESZEL_HUB_NGINX="${BESZEL_HUB_NGINX:-/etc/nginx/conf.d/beszel.conf}"
BESZEL_HUB_WAIT="${BESZEL_HUB_WAIT:-30}"

_bh_fail() { echo -e "${RED:-}❌ $*${NC:-}" >&2; return 1; }
_bh_say()  { echo -e "${C_DESC:-}   $*${NC:-}"; }

# Хаб отвечает на петле.
_bh_health() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        "http://${BESZEL_HUB_LOCAL}/api/health" 2>/dev/null)" = "200" ]
}

_bh_wait_health() {
    local i
    for ((i = 0; i < BESZEL_HUB_WAIT; i++)); do
        _bh_health && return 0
        sleep 1
    done
    return 1
}

# Учётной записи ещё нет: хаб ждёт первого пользователя.
#   0 — ждёт; 1 — уже есть; 2 — не ответил (не понять).
beszel_hub_first_run() {
    local out
    out="$(curl -s --max-time 5 "http://${BESZEL_HUB_LOCAL}/api/beszel/first-run" 2>/dev/null)"
    case "$out" in
        *'"firstRun":true'*)  return 0 ;;
        *'"firstRun":false'*) return 1 ;;
        *) return 2 ;;
    esac
}

# Порт хаба наружу — из нашего конфига nginx. Пусто — не выпущен.
_bh_nginx_port() {
    [ -r "$BESZEL_HUB_NGINX" ] || return 0
    grep -m1 -oP '^\s*listen\s+\K[0-9]+(?=\s+ssl)' "$BESZEL_HUB_NGINX"
}

# http2 в nginx до 1.25.1 включается в listen, после — отдельной директивой, а
# старую форму новые версии объявляют устаревшей. На 179 (Ubuntu 24.04,
# nginx 1.24) «http2 on;» не прошёл nginx -t.
_bh_nginx_new_http2() {
    local v="${BESZEL_HUB_NGINX_VERSION:-}"
    [ -n "$v" ] || v="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -n "$v" ] || return 1
    [ "$(printf '%s\n%s\n' "1.25.1" "$v" | sort -V | head -1)" = "1.25.1" ]
}

# Конфиг nginx на stdout: beszel_hub_nginx_render <домен> <порт>
beszel_hub_nginx_render() {
    local domain="$1" port="$2" h2_listen="" h2_line="" v6="#"
    if _bh_nginx_new_http2; then
        h2_line="    http2 on;"
    else
        h2_listen=" http2"
    fi
    # [::] — только если у ядра есть IPv6: без него nginx не поднимется вовсе
    # («Address family not supported»), и вместе с хабом упадут панель и маска.
    [ -e "${BESZEL_HUB_IF_INET6:-/proc/net/if_inet6}" ] && v6=""
    cat <<EOF
# >>> VSM beszel hub — файл создаёт VSM («Утилиты» → beszel → «Хаб»).
# Правки руками перезапишет следующая установка хаба.

limit_req_zone \$binary_remote_addr zone=vsm_beszel_auth:1m rate=10r/m;

map \$http_upgrade \$vsm_beszel_connection {
    default upgrade;
    ''      close;
}

# Без нашего имени — отказ на рукопожатии: по IP хаб не откликается.
server {
    listen ${port} ssl${h2_listen} default_server;
    ${v6}listen [::]:${port} ssl${h2_listen} default_server;
    ssl_reject_handshake on;
}

server {
    listen ${port} ssl${h2_listen};
    ${v6}listen [::]:${port} ssl${h2_listen};
${h2_line}
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 10m;

    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$vsm_beszel_connection;
    # Агенты держат WebSocket, страница — поток событий: без долгих таймаутов
    # и без буфера nginx рвал бы их каждую минуту.
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
    proxy_buffering off;

    # Подбор пароля — 10 попыток в минуту с адреса.
    location = /api/collections/users/auth-with-password {
        limit_req zone=vsm_beszel_auth burst=5 nodelay;
        limit_req_status 429;
        proxy_pass http://${BESZEL_HUB_LOCAL};
    }

    location / {
        proxy_pass http://${BESZEL_HUB_LOCAL};
    }
}
# <<< VSM beszel hub
EOF
}

_bh_run_installer() {
    local tmp
    tmp="$(mktemp /tmp/vsm-beszel-hub.XXXXXX.sh)" || return 1
    if ! curl -fsSL --max-time 60 "$BESZEL_HUB_INSTALLER_URL" -o "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        _bh_fail "не удалось скачать установщик хаба: $BESZEL_HUB_INSTALLER_URL"; return 1
    fi
    declare -F upstream_fingerprint >/dev/null 2>&1 \
        && upstream_fingerprint "$BESZEL_HUB_INSTALLER_URL" "$tmp"
    if ! sh "$tmp" --auto-update < /dev/null; then
        rm -f "$tmp"
        _bh_fail "установщик хаба завершился с ошибкой"; return 1
    fi
    rm -f "$tmp"
}

_bh_write_dropin() {
    mkdir -p "$(dirname "$BESZEL_HUB_DROPIN")" || return 1
    cat > "$BESZEL_HUB_DROPIN" <<EOF
# VSM: хаб слушает только петлю, наружу его отдаёт nginx по TLS.
[Service]
ExecStart=
ExecStart=${BESZEL_HUB_BIN} serve --http ${BESZEL_HUB_LOCAL}
EOF
}

# Первая учётная запись: email — аргумент, пароль — в BH_PASSWORD.
_bh_create_user() {
    local email="$1" code
    code="$(BH_EMAIL="$email" python3 -c '
import json, os
print(json.dumps({"email": os.environ["BH_EMAIL"], "password": os.environ["BH_PASSWORD"]}))' \
        | curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -H 'Content-Type: application/json' --data-binary @- \
            "http://${BESZEL_HUB_LOCAL}/api/beszel/create-user" 2>/dev/null)"
    [ "$code" = "200" ] || { _bh_fail "хаб не принял учётную запись (ответ ${code:-нет})"; return 1; }
    beszel_hub_first_run
    [ $? -eq 1 ] || { _bh_fail "учётная запись не появилась"; return 1; }
}

_bh_apply_nginx() {
    local domain="$1" port="$2" backup="" tmp code i
    if [ -f "$BESZEL_HUB_NGINX" ]; then
        backup="$(mktemp /tmp/vsm-beszel-nginx.XXXXXX)" && cp -p "$BESZEL_HUB_NGINX" "$backup"
    fi
    tmp="${BESZEL_HUB_NGINX}.vsm-tmp"
    beszel_hub_nginx_render "$domain" "$port" > "$tmp" && mv -f "$tmp" "$BESZEL_HUB_NGINX" \
        || { rm -f "$tmp"; _bh_fail "не удалось записать $BESZEL_HUB_NGINX"; return 1; }
    if ! nginx -t >/dev/null 2>&1; then
        nginx -t 2>&1 | tail -3 | sed 's/^/    /' >&2
        if [ -n "$backup" ]; then mv -f "$backup" "$BESZEL_HUB_NGINX"; else rm -f "$BESZEL_HUB_NGINX"; fi
        _bh_fail "nginx не принял конфиг хаба — прежний возвращён"; return 1
    fi
    rm -f "$backup"
    systemctl reload nginx || { _bh_fail "nginx не перечитал конфиг"; return 1; }
    # reload возвращается раньше, чем новые воркеры начинают отвечать.
    for ((i = 0; i < 15; i++)); do
        code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 \
            --resolve "${domain}:${port}:127.0.0.1" "https://${domain}:${port}/api/health" 2>/dev/null)"
        [ "$code" = "200" ] && return 0
        sleep 1
    done
    _bh_fail "https://${domain}:${port}/api/health → ${code:-нет ответа}"
}

_bh_open_port() {
    local port="$1" old="$2"
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0
    if [ -n "$old" ] && [ "$old" != "$port" ]; then
        ufw delete allow "${old}/tcp" >/dev/null 2>&1 || true
    fi
    ufw allow "${port}/tcp" comment 'beszel hub (VSM)' >/dev/null \
        || { _bh_fail "ufw не открыл ${port}/tcp"; return 1; }
    _bh_say "Порт ${port}/tcp открыт в фаерволе."
}

# ----------------------------------------------------------------------
# beszel_hub_install <домен> <порт> [email]  (пароль — в BH_PASSWORD)
# email нужен, только если учётной записи ещё нет.
# ----------------------------------------------------------------------
beszel_hub_install() {
    local domain="$1" port="$2" email="${3:-}" old_port busy fr
    [ -n "$domain" ] || { _bh_fail "не задан домен"; return 1; }
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
        || { _bh_fail "порт — число от 1 до 65535, получено: ${port:-пусто}"; return 1; }
    command -v nginx >/dev/null 2>&1 || { _bh_fail "nginx не установлен — хаб наружу выпускать нечем"; return 1; }
    [ -r "/etc/letsencrypt/live/${domain}/fullchain.pem" ] \
        || { _bh_fail "нет сертификата для ${domain} (/etc/letsencrypt/live/${domain})"; return 1; }
    old_port="$(_bh_nginx_port)"
    if [ "$port" != "$old_port" ]; then
        busy="$(ss -Htln "sport = :${port}" 2>/dev/null)"
        [ -z "$busy" ] || { _bh_fail "порт ${port} уже занят"; return 1; }
    fi

    # 1. Хаб на петле.
    if ! beszel_hub_installed; then
        _bh_write_dropin || { _bh_fail "не удалось записать $BESZEL_HUB_DROPIN"; return 1; }
        _bh_run_installer || return 1
    elif [ "$(beszel_hub_listen)" != "$BESZEL_HUB_LOCAL" ]; then
        _bh_write_dropin || { _bh_fail "не удалось записать $BESZEL_HUB_DROPIN"; return 1; }
        systemctl daemon-reload
        systemctl restart beszel-hub
    fi
    _bh_wait_health || { _bh_fail "хаб не ответил на ${BESZEL_HUB_LOCAL} за ${BESZEL_HUB_WAIT} с"; return 1; }
    [ "$(beszel_hub_listen)" = "$BESZEL_HUB_LOCAL" ] \
        || { _bh_fail "хаб слушает $(beszel_hub_listen), а не петлю — наружу не выпускаю"; return 1; }

    # 2. Учётная запись — до выхода наружу.
    beszel_hub_first_run; fr=$?
    case "$fr" in
        0) [ -n "$email" ] && [ -n "${BH_PASSWORD:-}" ] \
               || { _bh_fail "у хаба нет учётной записи, а email или пароль не заданы — наружу не выпускаю"; return 1; }
           _bh_create_user "$email" || return 1
           _bh_say "Учётная запись ${email} заведена." ;;
        1) _bh_say "Учётная запись в хабе уже есть — не трогаю." ;;
        *) _bh_fail "хаб не ответил, есть ли в нём учётная запись — наружу не выпускаю"; return 1 ;;
    esac

    # 3. Наружу.
    _bh_apply_nginx "$domain" "$port" || return 1
    _bh_open_port "$port" "$old_port" || return 1

    echo -e "${GREEN:-}✔ Хаб beszel $("$BESZEL_HUB_BIN" -v 2>/dev/null | awk '{print $NF}'): https://${domain}:${port}${NC:-}"
}
