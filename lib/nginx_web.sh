#!/bin/bash
#
# WEB Proxy telemt: блок в nginx и секции в конфиге движка.
#
# ЧТО ЭТО. Начиная с telemt 3.5.1 движок умеет гонять MTProto внутри обычного
# HTTPS или WebSocket. TLS движок не терминирует — публичный порт держит
# nginx, а движок слушает петлю и получает уже расшифрованное.
#
# ПОЧЕМУ НЕ ЧЕРЕЗ MTProxyL. Он это тоже умеет, но в режиме реаниматора
# отказывается: конфигом владеет цель, то есть мы. Проверено по коду 1.6.1 —
# web_enable() отказывает первой же строкой.
#
# ДВЕ ТОЧКИ ВХОДА, А НЕ ВЕСЬ ХОСТ. Шаблон MTProxyL отдаёт движку сайт целиком
# и показывает его заглушку вместо страницы. Здесь так нельзя: location /
# лежит в общем snippets/includes.conf, который подключают ОБА домена 3x-ui,
# и правка задела бы второй. Замер живого клиента 29.08.2026 показал, чего он
# просит на самом деле:
#
#   1. GET /?bridge=<токен>        — страница моста, с неё всё начинается
#   2. /api/v1/session|up|down|ws  — сам протокол
#
# Клиент, получив вместо страницы моста нашу статику, повторил запрос девять
# раз и сдался с «built-in web transport couldn't connect». Никаких других
# путей он не запрашивал.
#
# ЧУЖОЙ ФАЙЛ. vhost пишет установщик 3x-ui-pro и переписывает своим патчем
# целиком — вместе с нашим блоком. Пропажа беззвучна: сайт и панель отвечают
# как обычно, клиенты WEB просто перестают подключаться. За этим следит
# позиция реестра web_nginx_block, а возвращает пункт меню.

WEB_PROXY_BEGIN="# >>> VSM telemt WEB proxy"
WEB_PROXY_END="# <<< VSM telemt WEB proxy"

# Карты живут в conf.d намеренно: sites-enabled чужой патч чистит целиком, а
# conf.d переживает. Без карт nginx не соберётся вовсе.
WEB_MAP_FILE="/etc/nginx/conf.d/telemt-web-map.conf"

# Порт слушателя движка. Только петля: наружу его пускать нечем и незачем.
WEB_LISTEN_PORT="${WEB_LISTEN_PORT:-15080}"

# ----------------------------------------------------------------------
# Путь к файлу vhost, который nginx ДЕЙСТВИТЕЛЬНО читает.
#
# ЗАЧЕМ СВОЙ, А НЕ web_vhost_path. Тот предпочитает sites-available —
# так принято, когда sites-enabled это каталог ссылок. Но установщик
# 3x-ui-pro кладёт в sites-enabled ОБЫЧНЫЙ ФАЙЛ, а в sites-available свою
# отдельную копию, и это разные inode. Поймано 30.08.2026: блок лёг в
# sites-available, nginx его не увидел, WEB молча не работал — при том что и
# позиция реестра, и экран меню рапортовали «на месте», потому что смотрели
# в тот же неверный файл. Две проверки согласились, потому что обе ошибались
# одинаково; поймалось только запросом снаружи.
#
# nginx включает sites-enabled/*, поэтому истина там. readlink -f нужен для
# обычной раскладки, где это ссылка: править надо файл, а не ссылку.
# ----------------------------------------------------------------------
web_vhost_path() {
    local domain="$1" candidate
    for candidate in "/etc/nginx/sites-enabled/$domain" \
                     "/etc/nginx/conf.d/${domain}.conf" \
                     "/etc/nginx/sites-available/$domain"; do
        if [ -e "$candidate" ]; then
            readlink -f "$candidate"
            return 0
        fi
    done
    echo "не найден vhost домена $domain" >&2
    return 1
}

# ----------------------------------------------------------------------
# Карты для http-контекста.
# ----------------------------------------------------------------------
web_maps_write() {
    cat > "$WEB_MAP_FILE" <<'NGX'
# Карты для WEB Proxy telemt. Файл создан VSM, правки затрутся.
#
# Лежит в conf.d намеренно: установщик и патч 3x-ui-pro очищают
# sites-enabled целиком, и здесь файл это переживает.

map $http_upgrade $telemt_web_upgrade {
    default upgrade;
    ''      '';
}

# Пустая строка и ноль для nginx — ложь, всё остальное — истина. Поэтому
# «моста нет» обязано давать именно пустую строку.
map $arg_bridge $telemt_web_bridge {
    ''      '';
    default '1';
}
NGX
    chmod 644 "$WEB_MAP_FILE"
}

# ----------------------------------------------------------------------
# Текст блока для vhost.
# ----------------------------------------------------------------------
web_proxy_block() {
    local proxy
    proxy="        proxy_pass http://127.0.0.1:${WEB_LISTEN_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # real_ip_header proxy_protocol в этом vhost уже вернул настоящий
        # адрес клиента, поэтому \$remote_addr здесь — он, а не петля.
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$telemt_web_upgrade;

        proxy_connect_timeout 5s;
        proxy_send_timeout 65s;
        proxy_read_timeout 65s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_next_upstream off;

        # ОБЯЗАТЕЛЬНО off. На уровне сервера у 3x-ui-pro стоит
        # proxy_intercept_errors on плюс error_page ... =404, и без этой
        # строки любой ответ движка, кроме 2xx, превращался бы в 404 — ровно
        # так однажды 401 панели становился 404, и панель выглядела исправной
        # с наглухо неработающим API.
        proxy_intercept_errors off;

        # Движок недоступен — отвечаем тем же, чем этот путь отвечает без
        # WEB: обычным 404 от nginx. Иначе наружу ушёл бы 502 и сказал бы,
        # что за этим адресом что-то есть.
        error_page 502 503 504 = @web_down;"

    cat <<NGX
${WEB_PROXY_BEGIN} — не редактируй вручную
    # Корень отдаём движку ТОЛЬКО с параметром bridge: без него это обычный
    # сайт, и статику по-прежнему подаёт nginx.
    location = / {
        # if только с return — единственное безопасное его применение в
        # nginx. 418 здесь внутренняя метка, наружу не уходит.
        error_page 418 = @telemt_web;
        if (\$telemt_web_bridge) { return 418; }
        try_files \$uri \$uri/ =404;
    }

    location @telemt_web {
${proxy}
    }

    # ^~ вместо простого префикса: он останавливает подбор регулярных
    # выражений, среди которых в этом vhost есть ^/([0-9]+)/(.*).
    location ^~ /api/v1/ {
${proxy}
    }

    location @web_down { return 404; }
${WEB_PROXY_END}
NGX
}

# ----------------------------------------------------------------------
# Врезать блок в vhost домена. Идемпотентно: прежний блок снимается.
#
# 0 — применено; 1 — нет, причина в stderr.
# ----------------------------------------------------------------------
web_nginx_apply() {
    local domain="$1" vhost
    [ -n "$domain" ] || { echo "не задан домен для WEB Proxy" >&2; return 1; }

    vhost="$(web_vhost_path "$domain")" || return 1
    web_maps_write || { echo "не удалось записать $WEB_MAP_FILE" >&2; return 1; }

    # Общий помощник: снятие прежнего блока, поиск server{} с
    # ssl_certificate, nginx -t и откат — всё там. Своя копия жила
    # здесь ровно до тех пор, пока общая клала резервный файл рядом с
    # vhost; теперь она кладёт его вне каталога, и вторая копия стала
    # лишней. Две копии однажды разойдутся именно в обращении с откатом.
    panel_proxy_apply_block "$vhost" "$WEB_PROXY_BEGIN" "$WEB_PROXY_END" \
        "$(web_proxy_block)" "WEB Proxy"
}

# ----------------------------------------------------------------------
# Снять блок и карты. Нужно при удалении стека и при выключении WEB.
# ----------------------------------------------------------------------
web_nginx_remove() {
    local domain="$1" vhost content
    vhost="$(web_vhost_path "$domain" 2>/dev/null)" || return 0
    [ -f "$vhost" ] || return 0

    content="$(panel_proxy_strip "$WEB_PROXY_BEGIN" "$WEB_PROXY_END" < "$vhost")"
    printf '%s\n' "$content" > "$vhost" || return 1
    rm -f "$WEB_MAP_FILE"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
    return 0
}

# ----------------------------------------------------------------------
# Есть ли блок на месте. Для меню и отчётов.
# ----------------------------------------------------------------------
web_nginx_present() {
    local domain="$1" vhost
    vhost="$(web_vhost_path "$domain" 2>/dev/null)" || return 1
    [ -f "$vhost" ] || return 1
    grep -qF "$WEB_PROXY_BEGIN" "$vhost" 2>/dev/null && [ -r "$WEB_MAP_FILE" ]
}

# ======================================================================
# Секции WEB в конфиге движка
# ======================================================================
#
# САМОЕ ОПАСНОЕ МЕСТО ВО ВСЁМ ЭТОМ ФАЙЛЕ. Как только в конфиге появляется
# хоть один [[server.listeners]], поле [server] port перестаёт действовать
# ЦЕЛИКОМ — и MTProxy-слушателя приходится объявлять руками рядом с WEB.
# Ошибка здесь оставляет без связи всех клиентов FakeTLS сразу.
#
# Поэтому: копия до правки, проверка фактом после перезапуска (слушает ли
# движок публичный порт и отвечает ли маска сертификатом), откат при любом
# сомнении.

WEB_TOML="${WEB_TOML:-/etc/telemt/telemt.toml}"

web_toml_enabled() {
    grep -qE '^\[web\]' "$WEB_TOML" 2>/dev/null
}

# Имена включённых пользователей из [access.users].
web_toml_users() {
    awk '
        /^[[:space:]]*\[access\.users\]/ { inside=1; next }
        /^[[:space:]]*\[/               { inside=0 }
        inside && /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
            split($0, kv, "=")
            gsub(/[[:space:]]/, "", kv[1])
            if (kv[1] != "") print kv[1]
        }
    ' "$WEB_TOML" 2>/dev/null
}

# Публичный адрес для web.vhosts.public_addr.
#
# Это именно СОКЕТ, а не адрес: с голым IP движок не стартует с ошибкой
# invalid socket address syntax. Проверено на пробном экземпляре 29.08.2026 —
# в документации автора этого нет.
web_public_addr() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n1)"
    [ -n "$ip" ] || return 1
    printf '%s:443\n' "$ip"
}

# ----------------------------------------------------------------------
# Включить WEB в конфиге движка. Идемпотентно.
# ----------------------------------------------------------------------
web_toml_enable() {
    local domain="$1" addr proxy_port backup tmp user
    [ -n "$domain" ] || { echo "не задан домен WEB" >&2; return 1; }
    [ -r "$WEB_TOML" ] || { echo "не найден $WEB_TOML" >&2; return 1; }

    if web_toml_enabled; then
        return 0
    fi

    addr="$(web_public_addr)" || { echo "не определил публичный адрес сервера" >&2; return 1; }

    proxy_port="$(awk '
        /^[[:space:]]*\[server\]/ { inside=1; next }
        /^[[:space:]]*\[/         { inside=0 }
        inside && /^[[:space:]]*port[[:space:]]*=/ {
            split($0, kv, "="); gsub(/[[:space:]]/, "", kv[2]); print kv[2]; exit
        }
    ' "$WEB_TOML")"
    if [ -z "$proxy_port" ]; then
        echo "в $WEB_TOML нет [server] port — не понимаю конфиг, не трогаю" >&2
        return 1
    fi

    backup="${WEB_TOML}.vsm-before-web"
    cp -p "$WEB_TOML" "$backup" || { echo "не сохранил копию конфига" >&2; return 1; }

    tmp="$(mktemp)" || return 1
    awk -v port="$proxy_port" -v listen="$WEB_LISTEN_PORT" '
        /^[[:space:]]*\[server\][[:space:]]*$/ { skip=1; next }
        skip && /^[[:space:]]*port[[:space:]]*=/ {
            print "# Явные listener-ы отменяют поле [server] port целиком, поэтому"
            print "# MTProxy объявлен здесь наравне с WEB: без этой секции FakeTLS"
            print "# не поднимется. Секции создал VSM."
            print "[[server.listeners]]"
            print "ip = \"0.0.0.0\""
            print "port = " port
            print "transport = \"mtproxy\""
            print "proxy_protocol = false"
            print ""
            print "# WEB слушает только петлю: TLS терминирует nginx, сюда приходит"
            print "# уже расшифрованное, а настоящий адрес клиента — в X-Forwarded-For,"
            print "# которому мы верим только от петли."
            print "[[server.listeners]]"
            print "ip = \"127.0.0.1\""
            print "port = " listen
            print "transport = \"web\""
            print "proxy_protocol = false"
            print "reuse_allow = false"
            print "web_client_ip_source = \"x_forwarded_for\""
            print "web_trusted_proxy_cidrs = [\"127.0.0.1/32\"]"
            skip=0
            next
        }
        { print }
    ' "$WEB_TOML" > "$tmp" || { rm -f "$tmp"; return 1; }

    {
        echo ""
        echo "# WEB Proxy: MTProto внутри обычного HTTPS или WebSocket."
        echo "# carrier websocket-lanes выбран намеренно — он единственный, кто"
        echo "# нормально уживается с zapret2: тот зажимает окно в SYN+ACK, когда"
        echo "# SNI ещё неизвестен, и по домену его не обойти."
        echo "[web]"
        echo "enabled = true"
        echo 'carrier = "websocket-lanes"'
        echo ""
        echo "[web.debug]"
        echo "enabled = false"
        echo ""
        echo "# Домен тот же, что у FakeTLS: они на разных портах, путать нечего."
        echo "[[web.vhosts]]"
        echo "host = \"${domain}\""
        echo "public_addr = \"${addr}\""
        echo ""
        echo "# Заглушка — тот же каталог, что отдаёт nginx: содержимое страницы"
        echo "# не меняется, меняется только тот, кто её подаёт."
        echo "[web.vhosts.decoy]"
        echo 'mode = "static_directory"'
        echo 'directory = "/var/www/html"'
        echo 'index = "index.html"'
        while read -r user; do
            [ -n "$user" ] || continue
            echo ""
            echo "[[web.vhosts.profiles]]"
            echo "user = \"${user}\""
            echo 'secret_mode = "dd"'
        done <<< "$(web_toml_users)"
    } >> "$tmp"

    cat "$tmp" > "$WEB_TOML" || { rm -f "$tmp"; mv -f "$backup" "$WEB_TOML"; return 1; }
    rm -f "$tmp"
    chown --reference="$backup" "$WEB_TOML" 2>/dev/null || true
    return 0
}

# ----------------------------------------------------------------------
# Перезапуск движка с проверкой ФАКТОМ и откатом.
#
# Проверяем не код возврата systemctl — он вернёт 0 и для процесса, который
# поднялся калекой, — а то, что публичный порт слушается и маска отвечает
# сертификатом. С повторами: сразу после перезапуска движок ещё поднимает пул
# ME, и одиночный отрицательный ответ откатил бы исправный конфиг. Замерено
# 29.08.2026: маска отвечает через 15 секунд.
# ----------------------------------------------------------------------
web_engine_restart_verified() {
    local domain="$1" port="$2" waited=0 deadline="${3:-90}"
    systemctl restart telemt >/dev/null 2>&1
    while [ "$waited" -lt "$deadline" ]; do
        if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q . \
           && timeout 8 openssl s_client -connect "127.0.0.1:${port}" \
                -servername "$domain" </dev/null 2>&1 | grep -q "CN=${domain}"; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}
