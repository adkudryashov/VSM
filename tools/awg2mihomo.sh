#!/bin/bash
#
# Конвертер клиентского конфига AmneziaWG в формат mihomo (clash-meta).
#
# Появился потому, что перенос полей руками дважды дал нерабочий конфиг. Ошибки
# были не в значениях, а в структуре, и каждая выглядела как «VPN не работает»:
#
#   • параметры обфускации положили на верхний уровень прокси, тогда как mihomo
#     ждёт их во вложенном блоке amnezia-wg-option;
#   • preshared-key вместо pre-shared-key;
#   • dns-server вместо dns;
#   • потеряли persistent-keepalive, без которого туннель не поддерживается.
#
# Ни одна из них не видна по значениям — только по имени и месту ключа. Поэтому
# перенос делает скрипт, а не человек.
#
# Запуск:
#   bash tools/awg2mihomo.sh --from-panel [имя]   собрать из базы 3x-ui
#   bash tools/awg2mihomo.sh <файл>               конфиг из файла
#   bash tools/awg2mihomo.sh -                    конфиг со стандартного ввода
#   ... | bash tools/awg2mihomo.sh                то же
#
# Переменные: XUI_DB — путь к базе панели, AWG_ENDPOINT_HOST — адрес сервера,
# если определённый автоматически не подходит (сервер за NAT).
#
# Возврат: 0 — конфиг выдан, 1 — отказ с объяснением.

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[0;33m'; GRAY='\033[0;90m'; NC='\033[0m'
die()  { echo -e "${RED}[отказ]${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# РЕЖИМ --from-panel: конфиг собирается из базы 3x-ui, а не берётся файлом.
#
# ЗАЧЕМ. Панель умеет отдать клиентский .conf кнопкой, но собирает его
# ФРОНТЕНДОМ, в браузере: через API готового файла не получить. Значит путь
# пользователя был бы такой — скачать .conf на свой компьютер, залить обратно
# на сервер, здесь сконвертировать. Три лишних шага и приватный ключ, гуляющий
# по дороге. Проще прочитать то же самое из базы на месте.
#
# Формат сборки повторяет генератор панели (проверено по её бандлу 28.08.2026),
# с одним намеренным отличием — PersistentKeepalive ниже.
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"

_conf_from_panel() {
    local want_email="$1" row settings port email host ka
    command -v sqlite3 >/dev/null 2>&1 || die "Нужен sqlite3, а его нет."
    command -v jq      >/dev/null 2>&1 || die "Нужен jq, а его нет."
    [ -r "$XUI_DB" ] || die "База панели не читается: ${XUI_DB}"

    row="$(sqlite3 -json "$XUI_DB" \
        "select port, settings from inbounds where protocol='amneziawg' limit 1;" 2>/dev/null)"
    [ -n "$row" ] && [ "$row" != "[]" ] \
        || die "В панели нет соединения AmneziaWG. Создайте его: Подключения → Создать, протокол amneziawg."

    port="$(jq -r '.[0].port' <<< "$row")"
    settings="$(jq -r '.[0].settings' <<< "$row")"

    # Имя клиента. Пустое — берём единственного; если их несколько, молча взять
    # первого нельзя: выданный не тому человеку конфиг это не опечатка, а
    # чужой доступ.
    if [ -z "$want_email" ]; then
        local n
        n="$(jq -r '.clients | length' <<< "$settings")"
        [ "$n" -gt 0 ] || die "В соединении AmneziaWG нет ни одного клиента."
        if [ "$n" -gt 1 ]; then
            echo "Клиентов несколько — укажите имя вторым аргументом:" >&2
            jq -r '.clients[] | "  " + .email' <<< "$settings" >&2
            exit 1
        fi
        want_email="$(jq -r '.clients[0].email' <<< "$settings")"
    fi

    email="$want_email"
    jq -e --arg e "$email" '.clients[] | select(.email == $e)' <<< "$settings" >/dev/null 2>&1 \
        || die "Клиента «${email}» в соединении AmneziaWG нет."

    # Адрес, на который будет ходить клиент. Берём тот, с которого сервер
    # выходит наружу; за NAT он окажется внутренним — тогда задайте вручную
    # переменной AWG_ENDPOINT_HOST.
    host="${AWG_ENDPOINT_HOST:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')}"
    [ -n "$host" ] || die "Не определил внешний адрес сервера. Задайте AWG_ENDPOINT_HOST=адрес."

    # PersistentKeepalive: 25, если у клиента не задан свой.
    #
    # ОТСТУПЛЕНИЕ ОТ ПАНЕЛИ, И ОНО НАМЕРЕННОЕ. Панель пишет эту строку только
    # когда поле keepAlive у клиента заполнено, а по умолчанию оно пустое.
    # Клиент при этом почти всегда за NAT — на роутере иначе не бывает, — и без
    # периодических пакетов запись в таблице трансляции протухает за минуту-две.
    # Отказ выглядит как «работало, потом перестало, потом само починилось»,
    # то есть как что угодно, кроме настройки. 25 секунд — общепринятое
    # значение для WireGuard за NAT.
    ka="$(jq -r --arg e "$email" '(.clients[] | select(.email == $e) | .keepAlive) // 0' <<< "$settings")"
    [[ "$ka" =~ ^[0-9]+$ ]] && [ "$ka" -gt 0 ] || ka=25

    jq -r --arg e "$email" --arg port "$port" --arg host "$host" --arg ka "$ka" '
        .server as $s
        | (.clients[] | select(.email == $e)) as $c
        | [ "[Interface]",
            "PrivateKey = " + ($c.privateKey // ""),
            "Address = " + (($c.allowedIPs // []) | join(", ")) ]
          + ( [ $s.primaryDns, $s.secondaryDns ] | map(select(. != null and . != ""))
              | if length > 0 then [ "DNS = " + join(", ") ] else [] end )
          + ( if ($s.mtu // 0) > 0 then [ "MTU = " + ($s.mtu | tostring) ] else [] end )
          + [ "Jc = "   + ($s.jc   | tostring),
              "Jmin = " + ($s.jmin | tostring),
              "Jmax = " + ($s.jmax | tostring),
              "S1 = "   + ($s.s1   | tostring),
              "S2 = "   + ($s.s2   | tostring) ]
          + ( ["s3","s4"] | map(. as $k | if ($s[$k] // 0) > 0
                then ($k | ascii_upcase) + " = " + ($s[$k] | tostring) else empty end) )
          + ( ["h1","h2","h3","h4"] | map(. as $k | if ($s[$k] // "") != ""
                then ($k | ascii_upcase) + " = " + ($s[$k] | tostring) else empty end) )
          + ( ["i1","i2","i3","i4","i5"] | map(. as $k | if ($s[$k] // "") != ""
                then ($k | ascii_upcase) + " = " + ($s[$k] | tostring) else empty end) )
          + ( [ ["headerProtectionKey","HeaderProtectionKey"],
                ["contentPaddingAddition","ContentPaddingAddition"],
                ["rekeyAfterTime","RekeyAfterTime"],
                ["rekeyTimeout","RekeyTimeout"],
                ["rejectAfterTime","RejectAfterTime"],
                ["keepaliveTimeout","KeepaliveTimeout"],
                ["maxHandshakeAttempts","MaxHandshakeAttempts"] ]
              | map(. as $p | if ($s[$p[0]] // "") != ""
                    then $p[1] + " = " + ($s[$p[0]] | tostring) else empty end) )
          + ( if ($s.randomTrailers // false) then [ "RandomTrailers = on" ] else [] end )
          + ( if ($s.disableCookies // false) then [ "DisableCookies = on" ] else [] end )
          + [ "", "# " + $e, "[Peer]",
              "PublicKey = " + ($s.publicKey // "") ]
          + ( if (($c.preSharedKey // "") != "") then [ "PresharedKey = " + $c.preSharedKey ] else [] end )
          + [ "AllowedIPs = 0.0.0.0/0, ::/0",
              "Endpoint = " + $host + ":" + $port,
              "PersistentKeepalive = " + $ka ]
        | join("\n")
    ' <<< "$settings"
}

# die внутри _conf_from_panel выходит из ПОДОБОЛОЧКИ подстановки, а не из
# скрипта, поэтому проверка кода возврата здесь обязательна: без неё отказ
# напечатался бы в stderr, а работа продолжилась с пустым конфигом.
if [ "${1:-}" = "--from-panel" ]; then
    CONF="$(_conf_from_panel "${2:-}")" || exit 1
else
    SRC="${1:--}"
    if [ "$SRC" = "-" ]; then
        CONF="$(cat)"
    else
        [ -f "$SRC" ] || die "Файл не найден: $SRC"
        CONF="$(cat "$SRC")"
    fi
fi
[ -n "${CONF//[[:space:]]/}" ] || die "Пустой ввод."

# Значение ключа из секции. Секции различаем, потому что PublicKey есть только
# у пира, а PrivateKey только у интерфейса — брать их вслепую по имени нельзя.
# Ключ ищем без учёта регистра: разные генераторы пишут по-разному.
conf_get() { # секция ключ
    awk -v want_sec="$1" -v want_key="$2" '
        /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[^a-z]/, "", sec); next }
        {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            if (line !~ /=/) next
            key = line; sub(/=.*$/, "", key); gsub(/[[:space:]]/, "", key)
            val = line; sub(/^[^=]*=[[:space:]]*/, "", val)
            sub(/[[:space:]]+$/, "", val)
            if (sec == want_sec && tolower(key) == tolower(want_key)) { print val; exit }
        }
    ' <<< "$CONF"
}

# ---------------------------------------------------------------------------
# AmneziaWG 3.0 — поддерживается, но ТОЛЬКО с явным version: 3
#
# ЗДЕСЬ БЫЛ БЕЗУСЛОВНЫЙ ОТКАЗ, и он оказался неверным. Обоснование гласило:
# «mihomo знает AmneziaWG до 2.0, полей под защиту заголовков у него нет
# вовсе». На момент написания это было правдой; ко времени, когда владелец
# принёс свой конфиг, — уже нет. Проверено по исходникам mihomo v1.19.30
# (adapter/outbound/wireguard.go, структура AmneziaWGOption): там есть и
# header-protection-key, и content-padding-addition, и все пять таймингов.
#
# Цена ошибки была реальной: скрипт отказывал и советовал ПЕРЕУСТАНОВИТЬ
# сервер как 2.0, то есть предлагал понизить защиту из-за устаревшего знания
# о чужой программе.
#
# ГЛАВНОЕ ПРО version. В структуре mihomo:
#
#   Version int `proxy:"version,omitempty"`
#   // Only version 3 uses the v3 implementation; all other values use legacy.
#
# То есть без `version: 3` mihomo молча берёт СТАРУЮ реализацию, а ключи 3.0
# при ней не действуют. Рукопожатия не будет, и выглядеть это будет как
# «сервер не отвечает» — при полностью правильном на вид конфиге. Поэтому
# version проставляется здесь автоматически, а не оставляется человеку.
# ---------------------------------------------------------------------------
# Ищем по ВСЕМУ файлу, а не только в [Interface].
#
# Первая редакция смотрела только в секции интерфейса — там эти ключи и стоят у
# нашего генератора. Но признак «это 3.0» не должен зависеть от того, куда их
# положил чужой инструмент или человек: ключ 3.0 в любом месте означает 3.0.
IS_V3=0
for k in HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts; do
    if grep -qiE "^[[:space:]]*${k}[[:space:]]*=" <<< "$CONF"; then IS_V3=1; fi
done

# ---------------------------------------------------------------------------
# ПОЛЯ 3.1 — ПЕРЕНОСЯТСЯ, А НЕ ВЫБРАСЫВАЮТСЯ.
#
# Встроенный сервер 3x-ui 3.7.0 несёт amneziawg-go/v3 3.1 и включает
# RandomTrailers и DisableCookies САМ, по умолчанию, при создании inbound-а.
# В клиентский .conf панель пишет их строками вида "RandomTrailers = on".
#
# mihomo знает их с v1.19.30 (16.08.2026) как random-trailers и
# disable-cookies -- проверено по adapter/outbound/wireguard.go: поля стоят в
# AmneziaWGOption, а при их истинности в ipc уходит random_trailers=1 и
# disable_cookies=1. Ветку v3 включает всё то же version: 3, отдельного
# признака 3.1 у mihomo нет.
#
# Молча выбрасывать их нельзя: сервер добавляет к пакетам то, чего клиент не
# ждёт, и рукопожатия не будет БЕЗ единого сообщения об ошибке -- ровно тот
# отказ, что стоил пяти дней в прошлый раз, только причина другая. Поэтому они
# переносятся, а на старом mihomo о них предупреждают вслух ниже.
#
# Значение читаем, а не считаем непустоту ключа: "RandomTrailers = off"
# означает выключено, и включать его на клиенте было бы хуже пропуска.
V31_ON=""
for k in RandomTrailers DisableCookies; do
    v=$(grep -iE "^[[:space:]]*${k}[[:space:]]*=" <<< "$CONF" | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    case "$v" in
        on|true|1|yes)
            V31_ON="${V31_ON}${V31_ON:+ }${k}"
            IS_V3=1 ;;
    esac
done

PRIV=$(conf_get interface PrivateKey)
ADDR=$(conf_get interface Address)
MTU=$(conf_get interface MTU)
DNS=$(conf_get interface DNS)
PUB=$(conf_get peer PublicKey)
PSK=$(conf_get peer PresharedKey)
ALLOWED=$(conf_get peer AllowedIPs)
ENDPOINT=$(conf_get peer Endpoint)
KEEPALIVE=$(conf_get peer PersistentKeepalive)

[ -n "$PRIV" ]     || die "В конфиге нет [Interface] PrivateKey."
[ -n "$PUB" ]      || die "В конфиге нет [Peer] PublicKey."
[ -n "$ENDPOINT" ] || die "В конфиге нет [Peer] Endpoint — без адреса сервера подключаться некуда."
[ -n "$ADDR" ]     || die "В конфиге нет [Interface] Address."

# Адрес сервера и порт. Разбираем с конца: у IPv6-адреса двоеточий много, и
# делить по первому нельзя.
SRV_HOST="${ENDPOINT%:*}"
SRV_PORT="${ENDPOINT##*:}"
SRV_HOST="${SRV_HOST#[}"; SRV_HOST="${SRV_HOST%]}"
[[ "$SRV_PORT" =~ ^[0-9]+$ ]] || die "Не разобрал порт в Endpoint: ${ENDPOINT}"

# Адрес клиента без маски: mihomo ждёт в ip именно адрес, без /32.
IP4=""; IP6=""
IFS=',' read -ra _addrs <<< "$ADDR"
for a in "${_addrs[@]}"; do
    a="${a//[[:space:]]/}"; a="${a%%/*}"
    if [ -z "$a" ]; then continue; fi
    case "$a" in
        *:*) [ -z "$IP6" ] && IP6="$a" ;;
        *)   [ -z "$IP4" ] && IP4="$a" ;;
    esac
done
[ -n "$IP4" ] || die "Не нашёл адрес IPv4 клиента в Address: ${ADDR}"

# AllowedIPs в список YAML. ::/0 отбрасываем: адреса IPv6 у туннеля нет, он
# стоит там заглушкой против утечки — а у mihomo для этого своё dns.ipv6: false
# и собственный перехват, и лишний маршрут только путает.
AI_ITEMS=""
IFS=',' read -ra _ai <<< "${ALLOWED:-0.0.0.0/0}"
for a in "${_ai[@]}"; do
    a="${a//[[:space:]]/}"
    if [ -z "$a" ] || [ "$a" = "::/0" ]; then continue; fi
    AI_ITEMS="${AI_ITEMS}${AI_ITEMS:+, }'${a}'"
done
[ -n "$AI_ITEMS" ] || AI_ITEMS="'0.0.0.0/0'"

NAME="${AWG_MIHOMO_NAME:-AWG-$(printf '%s' "$SRV_HOST" | tr -c 'A-Za-z0-9.-' '-')}"

echo "proxies:"
echo "  - name: \"${NAME}\""
echo "    type: wireguard"
echo "    server: ${SRV_HOST}"
echo "    port: ${SRV_PORT}"
echo "    ip: ${IP4}"
[ -n "$IP6" ] && echo "    ipv6: ${IP6}"
echo "    private-key: \"${PRIV}\""
echo "    public-key: \"${PUB}\""
[ -n "$PSK" ] && echo "    pre-shared-key: \"${PSK}\""
echo "    allowed-ips: [${AI_ITEMS}]"
echo "    udp: true"
[ -n "$MTU" ] && echo "    mtu: ${MTU}"
# Без keepalive туннель поднимается и замолкает: проверено на стенде — после
# рукопожатия прошло несколько килобайт, и счётчики встали навсегда.
echo "    persistent-keepalive: ${KEEPALIVE:-25}"
if [ -n "$DNS" ]; then
    DNS_ITEMS=""
    IFS=',' read -ra _dns <<< "$DNS"
    for d in "${_dns[@]}"; do
        d="${d//[[:space:]]/}"
        if [ -z "$d" ]; then continue; fi
        DNS_ITEMS="${DNS_ITEMS}${DNS_ITEMS:+, }${d}"
    done
    [ -n "$DNS_ITEMS" ] && echo "    dns: [${DNS_ITEMS}]"
fi
# false, а не true. Значение проверено на живом клиенте владельца дважды: с true
# прокси помечался недоступным. Обратная сторона честная — запросы DNS уходят
# мимо туннеля, и провайдер их видит. Если у вас с true работает, ставьте true.
echo "    remote-dns-resolve: false"

# Обфускация — во ВЛОЖЕННОМ блоке. На верхнем уровне mihomo её не читает, и это
# была первая из ошибок ручного переноса.
#
# Числа и строки разделены намеренно. Диапазоны («238732873-238765132»,
# «111-133»), пакеты i1-i5 и ключ защиты заголовков — строки, и в YAML их
# нужно закавычить: i1 начинается с «<», а незакавыченное значение с таким
# началом читается не всегда одинаково. Числовые же поля закавычивать нельзя
# наоборот — mihomo ждёт в них int.
OBF=""
for k in Jc Jmin Jmax S1 S2 S3 S4; do
    v=$(conf_get interface "$k")
    if [ -n "$v" ]; then
        OBF="${OBF}      $(printf '%s' "$k" | tr 'A-Z' 'a-z'): ${v}"$'
'
    fi
done
for k in H1 H2 H3 H4 I1 I2 I3 I4 I5; do
    v=$(conf_get interface "$k")
    if [ -n "$v" ]; then
        OBF="${OBF}      $(printf '%s' "$k" | tr 'A-Z' 'a-z'): '${v}'"$'
'
    fi
done
# Ключи 3.0. Имена в mihomo кебабом, в конфиге AmneziaWG — слитно, поэтому
# соответствие задано явной таблицей, а не преобразованием регистра: угадывать
# здесь нечего, а ошибка в имени тихо выключит параметр.
if [ "$IS_V3" -eq 1 ]; then
    for pair in         "HeaderProtectionKey:header-protection-key"         "ContentPaddingAddition:content-padding-addition"         "RekeyAfterTime:rekey-after-time"         "RekeyTimeout:rekey-timeout"         "RejectAfterTime:reject-after-time"         "KeepaliveTimeout:keepalive-timeout"         "MaxHandshakeAttempts:max-handshake-attempts"; do
        v=$(conf_get interface "${pair%%:*}")
        if [ -n "$v" ]; then
            OBF="${OBF}      ${pair##*:}: '${v}'"$'
'
        fi
    done
    # 3.1 -- булевы, без кавычек: mihomo ждёт bool, а 'true' строкой он не
    # примет. omitempty на стороне mihomo означает, что false писать незачем.
    case " $V31_ON " in
        *" RandomTrailers "*) OBF="${OBF}      random-trailers: true"$'
' ;;
    esac
    case " $V31_ON " in
        *" DisableCookies "*) OBF="${OBF}      disable-cookies: true"$'
' ;;
    esac
fi
if [ -n "$OBF" ]; then
    echo "    amnezia-wg-option:"
    # version ПЕРВЫМ и только для 3.0. Без него mihomo берёт старую
    # реализацию, и все ключи ниже не действуют — молча.
    [ "$IS_V3" -eq 1 ] && echo "      version: 3"
    printf '%s' "$OBF"
fi

# Требование к версии mihomo названо вслух: поля 3.0 появились не сразу, и на
# сборке постарее они будут просто проигнорированы — то есть конфиг примут, а
# туннель не встанет.
if [ "$IS_V3" -eq 1 ]; then
    warn "Это конфиг AmneziaWG 3.0. Нужен mihomo, который знает version: 3"
    warn "  (проверено на v1.19.30). На сборке постарее поля 3.0 будут молча"
    warn "  проигнорированы, и рукопожатие не пройдёт."
    if [ -n "$V31_ON" ]; then
        warn "Плюс поля 3.1: ${V31_ON}. Их mihomo знает только с v1.19.30."
        warn "  Сборка постарее примет конфиг и не соединится, ничего не сказав."
    fi
fi
exit 0
