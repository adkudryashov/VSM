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
# Отказ на 3.0 — главное, что делает этот скрипт
#
# mihomo знает AmneziaWG до 2.0 включительно: jc/jmin/jmax, s1-s4, h1-h4,
# i1-i5. Полей под защиту заголовков и добивку содержимого у него нет вовсе.
#
# А защита заголовков меняет формат пакета в проводе: заголовок шифруется
# ChaCha20 с nonce из первых 12 байт S-паддинга. Клиент, который про неё не
# знает, не может ни разобрать чужой пакет, ни собрать свой — рукопожатия не
# будет. Снаружи это выглядит как «сервер не отвечает», и по конфигу причина не
# видна: все привычные параметры на месте. Ровно на это владелец и потратил
# вечер, прежде чем причина нашлась.
#
# Поэтому здесь отказ, а не предупреждение: выдать такой конфиг значит выдать
# заведомо нерабочий.
# ---------------------------------------------------------------------------
# Ищем по ВСЕМУ файлу, а не только в [Interface].
#
# Первая редакция смотрела только в секции интерфейса — там эти ключи и стоят у
# нашего генератора. Но проверка на «это 3.0» не должна зависеть от того, куда
# их положил чужой инструмент или человек: ключ 3.0 в любом месте означает 3.0,
# и пропустить его дороже, чем перестраховаться. Поймано приёмкой, где ключ
# оказался дописан в конец файла и отказ не сработал.
V3=""
for k in HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts; do
    if grep -qiE "^[[:space:]]*${k}[[:space:]]*=" <<< "$CONF"; then V3="${V3}${k} "; fi
done
if [ -n "$V3" ]; then
    echo -e "${RED}Это конфиг AmneziaWG 3.0, и mihomo его не поймёт.${NC}" >&2
    echo -e "${GRAY}Найдены ключи 3.0: ${V3}${NC}" >&2
    echo -e "${GRAY}mihomo и clash-meta знают AmneziaWG до 2.0: jc/jmin/jmax, s1-s4,${NC}" >&2
    echo -e "${GRAY}h1-h4, i1-i5. Поля под защиту заголовков у них нет, а она меняет${NC}" >&2
    echo -e "${GRAY}формат пакета — рукопожатие не пройдёт, и выглядеть это будет как${NC}" >&2
    echo -e "${GRAY}«сервер не отвечает».${NC}" >&2
    die "Переустановите AmneziaWG как 2.0 и выдайте конфиг заново."
fi

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
OBF=""
for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
    v=$(conf_get interface "$k")
    if [ -n "$v" ]; then
        OBF="${OBF}      $(printf '%s' "$k" | tr 'A-Z' 'a-z'): ${v}"$'\n'
    fi
done
if [ -n "$OBF" ]; then
    echo "    amnezia-wg-option:"
    printf '%s' "$OBF"
fi

# Предупреждение, а не отказ: без I-пакетов рукопожатие проходит, они лишь
# мусор перед ним. Но не всякая сборка mihomo их знает, и если журнал ругается
# на i1-i5 — их надо просто убрать.
if [ -n "$(conf_get interface I1)" ]; then
    warn "Если mihomo ругается на i1-i5 — уберите их. Сервер такого клиента примет:"
    warn "  I-пакеты это мусор перед рукопожатием, без них оно проходит."
fi
exit 0
