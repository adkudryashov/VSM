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
#   bash tools/awg2mihomo.sh <файл>       конфиг из файла
#   bash tools/awg2mihomo.sh -            конфиг со стандартного ввода
#   ... | bash tools/awg2mihomo.sh        то же
#
# Возврат: 0 — конфиг выдан, 1 — отказ с объяснением.

set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[0;33m'; GRAY='\033[0;90m'; NC='\033[0m'
die()  { echo -e "${RED}[отказ]${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }

SRC="${1:--}"
if [ "$SRC" = "-" ]; then
    CONF="$(cat)"
else
    [ -f "$SRC" ] || die "Файл не найден: $SRC"
    CONF="$(cat "$SRC")"
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
fi
exit 0
