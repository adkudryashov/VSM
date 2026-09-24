# shellcheck shell=bash
# Подписка mihomo для роутера с XKeen и кнопка «XKeen» на странице подписки.
#
# ЗАЧЕМ. На роутере владельца mihomo в XKeen. Раньше ему нужны были две вещи:
# обычная подписка (VLESS/trojan/hy2 ссылками) и ОТДЕЛЬНЫЙ блок proxies с
# ключами AmneziaWG, собранный руками или пунктом «AmneziaWG для роутера».
# После переустановки сервера ключи AWG новые, и блок надо переносить заново.
#
# 3x-ui 3.8 умеет отдавать подписку сразу в формате mihomo, и AWG в ней уже
# есть — с version: 3 и полями 3.1 (проверено по коду 3.8.5,
# internal/sub/clash_service.go, и выдачей на стенде 24.09.2026). Роутеру
# достаточно одного proxy-provider — новые ключи он подтянет сам.
#
# ЧЕГО НЕ ХВАТАЛО. Подписка mihomo в панели выключена по умолчанию, а nginx
# 3x-ui-pro пускает только обычную подписку и JSON — путь mihomo отдавал бы
# 404. И на странице подписки нет вкладки для роутера: Android и iOS зашиты в
# её код. Правку nginx и вставку кнопки делает tools/xui-mihomo.py, сама
# кнопка — tools/xui-sub-xkeen.js.
#
# ЦЕНА ВКЛЮЧЕНИЯ — перезапуск x-ui: настройки подписки панель читает при
# старте. Клиенты переподключаются за несколько секунд.

XUI_MIHOMO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
XUI_MIHOMO_TOOL="${XUI_MIHOMO_ROOT}/tools/xui-mihomo.py"
XUI_MIHOMO_JS_SRC="${XUI_MIHOMO_ROOT}/tools/xui-sub-xkeen.js"
XUI_MIHOMO_JS="${XUI_MIHOMO_JS:-/var/www/vsm-sub/xkeen.js}"
XUI_MIHOMO_NGINX="${XUI_MIHOMO_NGINX:-/etc/nginx}"
XUI_MIHOMO_BACKUP_DIR="${XUI_MIHOMO_BACKUP_DIR:-/var/backups/vsm/nginx}"
XUI_MIHOMO_WAIT="${XUI_MIHOMO_WAIT:-30}"

_xm_db()   { echo "${XUI_DB:-/etc/x-ui/x-ui.db}"; }
_xm_say()  { echo -e "$*"; }
_xm_fail() { echo -e "${RED:-}❌ $*${NC:-}" >&2; return 1; }
_xm_norm() { local p="${1#/}"; echo "${p%/}"; }

# .timeout обязателен. Первые доли секунды после перезапуска панель держит
# базу, и sqlite3 без ожидания сразу отвечает «database is locked». Поймано
# 24.09.2026: ошибка ушла в /dev/null, пустой ответ прочитался как «subURI
# не задан», и включение откатилось на исправной панели. Воспроизводилось
# через раз — окно около 100 мс.
_xm_sql() { sqlite3 -cmd ".timeout 5000" "$(_xm_db)" "$@"; }

_xm_get() {
    _xm_sql "select value from settings where key='$1' limit 1;" 2>/dev/null
}

# Значения сюда приходят только наши: true/false и путь из hex — кавычек в
# них нет, подставлять в SQL можно.
_xm_put() {
    if [ -n "$(_xm_sql "select 1 from settings where key='$1';" 2>/dev/null)" ]; then
        _xm_sql "update settings set value='$2' where key='$1';"
    else
        _xm_sql "insert into settings(key, value) values('$1', '$2');"
    fi
}

# Файл nginx, где лежит location подписки. У 3x-ui-pro это
# snippets/includes.conf, но ищем по содержимому: раскладка — чужая.
xui_mihomo_conf() {
    local sub f
    sub="$(_xm_norm "$1")"
    [ -n "$sub" ] || return 1
    for f in "$XUI_MIHOMO_NGINX"/snippets/*.conf "$XUI_MIHOMO_NGINX"/sites-enabled/* \
             "$XUI_MIHOMO_NGINX"/conf.d/*.conf; do
        [ -f "$f" ] || continue
        if grep -qF "location ~ ^/${sub}/(" "$f" 2>/dev/null \
           || grep -qF "location /${sub}/ {" "$f" 2>/dev/null; then
            readlink -f "$f"
            return 0
        fi
    done
    return 1
}

# Клиент, на подписке которого проверяем выдачу: первый включённый.
_xm_subid() {
    python3 - "$(_xm_db)" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
try:
    r = c.execute("select sub_id from clients where sub_id <> '' and enable limit 1").fetchone()
    if r:
        print(r[0]); sys.exit()
except sqlite3.OperationalError:
    pass
for (s,) in c.execute("select settings from inbounds where enable"):
    try:
        for cl in json.loads(s).get("clients", []):
            if cl.get("subId") and cl.get("enable", True):
                print(cl["subId"]); sys.exit()
    except ValueError:
        continue
PY
}

# Домен, под которым панель отдаёт подписку, — из subURI.
_xm_domain() {
    local uri
    uri="$(_xm_get subURI)"
    uri="${uri#*://}"
    uri="${uri%%/*}"
    echo "${uri%%:*}"
}

# ----------------------------------------------------------------------
# Состояние одной строкой: on | off | partial: <что не так>.
# 0 — включено и цело.
# ----------------------------------------------------------------------
xui_mihomo_state() {
    local sub clash conf st miss=()
    [ -r "$(_xm_db)" ] || { echo "off"; return 1; }
    [ "$(_xm_get subClashEnable)" = "true" ] || { echo "off"; return 1; }
    sub="$(_xm_get subPath)"
    clash="$(_xm_get subClashPath)"
    conf="$(xui_mihomo_conf "$sub")" || { echo "partial: не найден конфиг nginx подписки"; return 1; }
    st="$(python3 "$XUI_MIHOMO_TOOL" status --conf "$conf" --sub-path "$sub" --clash-path "$clash" 2>/dev/null)"
    grep -q '"clash_location": true' <<< "$st" || miss+=("путь mihomo в nginx")
    grep -q '"sub_filter": true' <<< "$st"     || miss+=("вставка кнопки")
    grep -q '"js_location": true' <<< "$st"    || miss+=("отдача скрипта")
    [ -r "$XUI_MIHOMO_JS" ]                    || miss+=("файл скрипта")
    if [ "${#miss[@]}" -eq 0 ]; then
        echo "on"
        return 0
    fi
    local joined
    joined="$(printf '%s, ' "${miss[@]}")"
    echo "partial: нет — ${joined%, }"
    return 1
}

# ----------------------------------------------------------------------
# Проверка фактом, снаружи через nginx: подписка mihomo отдаёт YAML с
# proxies, страница подписки несёт скрипт кнопки, скрипт отдаётся.
#
# Всё, что читается из базы, вызывающий читает ДО перезапуска панели и
# передаёт сюда: сразу после перезапуска база занята.
#   _xm_verify <домен> <путь подписки> <путь mihomo> [id клиента]
# ----------------------------------------------------------------------
_xm_verify() {
    local domain="$1" sub clash sid="${4:-}" tmp code i
    sub="$(_xm_norm "$2")"
    clash="$(_xm_norm "$3")"
    tmp="$(mktemp)"

    _get() {
        curl -sk -o "$tmp" -w '%{http_code}' --max-time 10 \
            --resolve "$domain:443:127.0.0.1" "$@" 2>/dev/null
    }

    # Первым — скрипт кнопки, С ПОВТОРАМИ. systemctl reload nginx
    # возвращается раньше, чем новые воркеры начинают отвечать, и первые
    # запросы получают старый конфиг — 404. Поймано 24.09.2026 на свежей
    # установке: клиентов нет, проверка шла одним запросом и откатывала
    # исправную правку. На стенде это пряталось: там сначала ждали подписку.
    for ((i = 0; i < XUI_MIHOMO_WAIT; i++)); do
        code="$(_get "https://$domain/$sub/__vsm/xkeen.js")"
        [ "$code" = "200" ] && break
        sleep 1
    done
    if [ "$code" != "200" ] || ! grep -q '__SUB_PAGE_DATA__' "$tmp"; then
        echo "скрипт кнопки отдаётся с кодом $code" >&2
        rm -f "$tmp"; return 1
    fi

    # Свежая панель бывает без клиентов: подписку проверить не на ком, но
    # это не повод откатывать — проверяем то, что можно, и говорим об этом.
    if [ -z "$sid" ]; then
        rm -f "$tmp"
        echo -e "${YELLOW:-}❗  Клиентов нет — выдачу подписки проверить не на ком.${NC:-}" >&2
        return 0
    fi

    # Панель после перезапуска поднимает сервер подписок не сразу.
    for ((i = 0; i < XUI_MIHOMO_WAIT; i++)); do
        code="$(_get "https://$domain/$clash/$sid")"
        [ "$code" = "200" ] && break
        sleep 1
    done
    if [ "$code" != "200" ] || ! grep -q '^proxies:' "$tmp"; then
        echo "подписка mihomo отвечает $code без списка proxies" >&2
        rm -f "$tmp"; return 1
    fi
    # Адрес сервера у подключений. Запрос идёт с петли, и если панель взяла
    # адрес из X-Real-IP, здесь будет localhost — ровно тот дефект, из-за
    # которого роутер получал в AWG свой собственный IP.
    if grep -qE '^[[:space:]]*(-[[:space:]]+)?server:[[:space:]]*"?(localhost|127\.0\.0\.1)"?[[:space:]]*$' "$tmp"; then
        echo "в подписке адрес сервера — петля: панель подставила адрес запросившего" >&2
        rm -f "$tmp"; return 1
    fi

    code="$(_get -H 'Accept: text/html' "https://$domain/$sub/$sid")"
    if [ "$code" != "200" ] || ! grep -qF '__vsm/xkeen.js' "$tmp"; then
        echo "страница подписки ($code) пришла без скрипта кнопки" >&2
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
    return 0
}

# Отказ systemd «start of the service was attempted too often» снимаем
# reset-failed и пробуем ещё раз. Без этого откат, который тоже перезапускает
# панель, упирался в тот же предел и оставлял её лежать. Поймано 24.09.2026
# на стенде серией включений подряд: x-ui простояла в failed около минуты.
_xm_restart_xui() {
    local i
    if ! systemctl restart x-ui 2>/dev/null; then
        systemctl reset-failed x-ui 2>/dev/null
        systemctl restart x-ui || return 1
    fi
    for ((i = 0; i < XUI_MIHOMO_WAIT; i++)); do
        systemctl is-active --quiet x-ui && return 0
        sleep 1
    done
    return 1
}

# ----------------------------------------------------------------------
# Включить или починить. Повтор безопасен: прежние куски nginx снимаются и
# ставятся заново. Любой сбой — откат nginx и настроек панели.
# ----------------------------------------------------------------------
xui_mihomo_enable() {
    local c db sub port clash was_on was_path conf tmp backup why domain sid
    for c in sqlite3 python3 nginx curl openssl; do
        command -v "$c" >/dev/null 2>&1 || { _xm_fail "нужен $c, а его нет"; return 1; }
    done
    db="$(_xm_db)"
    [ -r "$db" ] || { _xm_fail "нет базы 3x-ui: $db"; return 1; }
    [ "$(_xm_get subEnable)" = "true" ] || { _xm_fail "подписки в панели выключены (Настройки → Подписка)"; return 1; }

    sub="$(_xm_get subPath)"
    port="$(_xm_get subPort)"
    was_on="$(_xm_get subClashEnable)"
    was_path="$(_xm_get subClashPath)"
    domain="$(_xm_domain)"
    sid="$(_xm_subid)"
    [ -n "$sub" ] && [ -n "$port" ] || { _xm_fail "в панели не заданы путь или порт подписки"; return 1; }
    [ -n "$domain" ] || { _xm_fail "в панели не задан subURI — не знаю домен подписки"; return 1; }

    # Путь mihomo: свой случайный, если установщик его не задал или задал
    # общеизвестный. Секрет в ссылке — id клиента, но лишняя примета
    # «здесь 3x-ui» по пути /clash/ ни к чему.
    clash="$was_path"
    case "$(_xm_norm "$clash")" in
        ""|clash|mihomo|clash-legacy|"$(_xm_norm "$sub")") clash="/$(openssl rand -hex 9)/" ;;
    esac

    conf="$(xui_mihomo_conf "$sub")" \
        || { _xm_fail "не найден конфиг nginx с подпиской — это не установка 3x-ui-pro?"; return 1; }

    install -d -m 755 "$(dirname "$XUI_MIHOMO_JS")" \
        && install -m 644 "$XUI_MIHOMO_JS_SRC" "$XUI_MIHOMO_JS" \
        || { _xm_fail "не удалось положить скрипт кнопки в $XUI_MIHOMO_JS"; return 1; }

    tmp="$(mktemp)"
    if ! python3 "$XUI_MIHOMO_TOOL" render --conf "$conf" --sub-path "$sub" \
            --clash-path "$clash" --port "$port" --js-file "$XUI_MIHOMO_JS" > "$tmp"; then
        rm -f "$tmp"
        _xm_fail "правка nginx не собрана"; return 1
    fi
    mkdir -p "$XUI_MIHOMO_BACKUP_DIR" && chmod 700 "$XUI_MIHOMO_BACKUP_DIR"
    backup="$XUI_MIHOMO_BACKUP_DIR/$(basename "$conf").vsm-mihomo-bak"
    cp -p "$conf" "$backup" || { rm -f "$tmp"; _xm_fail "не удалось сохранить копию $conf"; return 1; }
    # cat, а не mv: у чужого файла остаются владелец, права и inode.
    cat "$tmp" > "$conf"
    rm -f "$tmp"
    if ! nginx -t >/dev/null 2>&1; then
        cat "$backup" > "$conf"
        _xm_fail "nginx -t отверг правку — файл возвращён"; return 1
    fi

    _xm_put subClashPath "$clash" && _xm_put subClashEnable true
    if ! _xm_restart_xui; then
        why="x-ui не поднялась после перезапуска"
    elif ! systemctl reload nginx; then
        why="nginx не перечитал конфиг"
    else
        if why="$(_xm_verify "$domain" "$sub" "$clash" "$sid" 2>&1)"; then
            [ -n "$why" ] && echo -e "$why"
            rm -f "$backup"
            return 0
        fi
    fi

    # Откат: nginx, настройки, перезапуск.
    cat "$backup" > "$conf"
    _xm_put subClashEnable "${was_on:-false}"
    [ -n "$was_path" ] && _xm_put subClashPath "$was_path"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    if ! _xm_restart_xui; then
        _xm_fail "не заработало: ${why}. Настройки возвращены, но x-ui НЕ ЗАПУСТИЛАСЬ:"
        _xm_fail "    systemctl status x-ui; journalctl -u x-ui -n 50"
        return 1
    fi
    _xm_fail "не заработало: ${why}. Всё возвращено как было."
    return 1
}

# ----------------------------------------------------------------------
# Выключить: снять куски nginx, скрипт и подписку mihomo в панели.
# ----------------------------------------------------------------------
xui_mihomo_disable() {
    local sub conf tmp backup
    sub="$(_xm_get subPath)"
    if conf="$(xui_mihomo_conf "$sub")"; then
        tmp="$(mktemp)"
        python3 "$XUI_MIHOMO_TOOL" strip --conf "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
        mkdir -p "$XUI_MIHOMO_BACKUP_DIR" && chmod 700 "$XUI_MIHOMO_BACKUP_DIR"
        backup="$XUI_MIHOMO_BACKUP_DIR/$(basename "$conf").vsm-mihomo-bak"
        cp -p "$conf" "$backup"
        cat "$tmp" > "$conf"
        rm -f "$tmp"
        if ! nginx -t >/dev/null 2>&1; then
            cat "$backup" > "$conf"
            _xm_fail "nginx -t не принял конфиг без наших кусков — файл возвращён"; return 1
        fi
        rm -f "$backup"
        systemctl reload nginx
    fi
    rm -f "$XUI_MIHOMO_JS"
    _xm_put subClashEnable false
    _xm_restart_xui
}
