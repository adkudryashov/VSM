#!/bin/bash

# ======================================================================
# ДОСТУП К MTProxyL-Panel ЧЕРЕЗ 443 ДОМЕНА ПАНЕЛИ
#
# Та же схема, что у telemt_panel: панель слушает только 127.0.0.1, TLS
# терминирует nginx сертификатом сайта, а попасть внутрь можно по случайному
# префиксу пути на обычном 443. Снаружи новых портов нет.
#
# Требует, чтобы lib/nginx_panel_proxy.sh был подключён раньше: оттуда берутся
# panel_proxy_strip, panel_proxy_insert, panel_proxy_apply_block и
# panel_proxy_verify. Своих копий здесь нет намеренно.
#
# ЧЕМ ПРОЩЕ, ЧЕМ У telemt_panel. Той приходится подделывать <base href> и
# window.__BASE_PATH__ через sub_filter: она собрана под работу от корня и из
# подкаталога отдавала белый экран. MTProxyL-Panel умеет base_path сама — в
# её конфиге стоит тот же префикс, и она срезает его с входящих запросов
# внутри себя. Поэтому proxy_pass передаёт путь КАК ЕСТЬ, вместе с префиксом,
# и никакой подмены тела ответа не нужно. Строка взята из документации автора:
#
#   nginx: location /panel123/ { proxy_pass http://127.0.0.1:8080/panel123/; }
#
# ВАЖНО: префикс здесь и base_path в /etc/mtproxyl-panel/config.toml обязаны
# совпадать. Разойдутся — панель ответит 404 на собственные ресурсы, причём
# страница входа откроется, а дальше ничего работать не будет.
# ======================================================================

MTPL_PROXY_BEGIN="# >>> VSM MTProxyL-Panel proxy — не редактируй вручную"
MTPL_PROXY_END="# <<< VSM MTProxyL-Panel proxy"

mtpl_proxy_render() {
    local prefix="$1" port="$2"

    cat << EOF
${MTPL_PROXY_BEGIN}
    location /${prefix}/ {
        # Со слэшем и С префиксом: панель срезает его сама по base_path.
        # Убрать префикс здесь (как сделано для telemt_panel) значит отдать ей
        # путь от корня, которого она не ждёт, — получите 404 на всё.
        proxy_pass http://127.0.0.1:${port}/${prefix}/;
        proxy_http_version 1.1;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Панель тянет живые данные потоком: трафик, состояние писателей,
        # журнал. Без апгрейда соединение рвётся по таймауту, и графики
        # замирают БЕЗ сообщения об ошибке — то есть выглядит как «данные не
        # меняются», а не как поломка.
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
${MTPL_PROXY_END}
EOF
}

# ----------------------------------------------------------------------
# Подключение. Аргументы: vhost, префикс, порт панели.
# ----------------------------------------------------------------------
mtpl_proxy_apply() {
    local vhost="$1" prefix="$2" port="$3"

    if ! printf '%s' "$prefix" | grep -qE '^[A-Za-z0-9_-]+$'; then
        echo "недопустимый префикс пути MTProxyL-Panel: '$prefix'" >&2
        return 1
    fi
    if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        echo "нужен числовой порт MTProxyL-Panel (получено '$port')" >&2
        return 1
    fi

    panel_proxy_apply_block "$vhost" "$MTPL_PROXY_BEGIN" "$MTPL_PROXY_END" \
        "$(mtpl_proxy_render "$prefix" "$port")" "MTProxyL-Panel"
}

mtpl_proxy_remove() {
    panel_proxy_remove "$1" "$MTPL_PROXY_BEGIN" "$MTPL_PROXY_END"
}

# ----------------------------------------------------------------------
# Чтение настроек панели из её собственного конфига.
#
# Не спрашиваем и не храним у себя: единственный источник правды — тот файл,
# по которому панель реально работает. Расхождение здесь даёт неработающий
# адрес при полностью исправной панели, и искать причину придётся долго.
# ----------------------------------------------------------------------
MTPL_PANEL_CONF="${MTPL_PANEL_CONF:-/etc/mtproxyl-panel/config.toml}"

mtpl_panel_prefix() {
    [ -r "$MTPL_PANEL_CONF" ] || return 0
    sed -n 's/^[[:space:]]*base_path[[:space:]]*=[[:space:]]*"\/\{0,1\}\([^"]*\)".*/\1/p' \
        "$MTPL_PANEL_CONF" | head -1 | tr -d '/'
}

# Адрес, по которому панель открывается снаружи. Собирается из домена панели
# VSM и префикса из ЕЁ конфига: два источника, но оба единственно верные —
# домен знает только VSM, префикс только панель.
#
# Пусто, если чего-то из двух нет: печатать половину адреса хуже, чем не
# печатать ничего.
mtpl_panel_url() {
    local conf="${VSM_TELEMT_CONF:-/etc/vsm/telemt.conf}" domain prefix
    [ -r "$conf" ] || return 0
    domain="$(grep -m1 -oP '^DOMAIN_PANEL=\K.*' "$conf" 2>/dev/null | tr -d "\"'")"
    prefix="$(mtpl_panel_prefix)"
    [ -n "$domain" ] && [ -n "$prefix" ] || return 0
    printf 'https://%s/%s/' "$domain" "$prefix"
}

mtpl_panel_port() {
    [ -r "$MTPL_PANEL_CONF" ] || return 0
    sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*"[^":]*:\([0-9]\+\)".*/\1/p' \
        "$MTPL_PANEL_CONF" | head -1
}

# Слушает ли панель только loopback. Отдавать наружу панель, которая и сама
# висит на 0.0.0.0, бессмысленно: секретный префикс не спрячет открытый порт.
mtpl_panel_is_local() {
    [ -r "$MTPL_PANEL_CONF" ] || return 1
    grep -qE '^[[:space:]]*listen[[:space:]]*=[[:space:]]*"127\.0\.0\.1:' "$MTPL_PANEL_CONF"
}
