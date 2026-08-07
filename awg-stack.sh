#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AmneziaWG 2.0 / 3.0 — установка рядом с работающим стеком VSM
#
# ЗАЧЕМ ИМЕННО ЭТОТ ИСТОЧНИК. Обфускация 3.0 (диапазоны H1-H4, пакеты I1-I5,
# HeaderProtectionKey, рандомизированные тайминги) штатным серверным
# инструментом не подаётся вовсе: `awg setconf` этих ключей не знает.
# Единственный найденный путь — контейнеры Vadim-Khristenko/awg-containers-and-tools,
# где конфигурация уходит демону напрямую через UAPI-сокет.
#
# 2.0 берётся ОТТУДА ЖЕ, образом vaiprog/amnezia-wg-2. Отдельный установщик под
# 2.0 (wiresock: PPA + модуль ядра через DKMS) рассматривался и отвергнут: он
# рабочий, но это второй механизм установки со своей поверхностью конфликтов —
# сборка модуля против ядра, apt-репозиторий, свои правила NAT, — ради версии,
# которая тем же семейством контейнеров уже покрыта. Один проверенный путь на
# обе версии дешевле двух.
#
# Рассмотренные и отвергнутые:
#   wiresock/amneziawg-install  — только 2.0, и модуль ядра вместо контейнера;
#   bivlked/amneziawg-installer — заявляет 3.0, но накатывает свою политику UFW
#                                 «входящие запрещены, открыт только порт VPN».
#                                 На нашем сервере это закрыло бы 443, 80 и порт
#                                 telemt, то есть убило бы панель, маскировку и
#                                 прокси молча. Плюс требует двух перезагрузок.
#   Any-Tech-ARCHITECT          — не установщик, а генератор параметров.
#
# ВАЖНО ПРО HOST-РЕЖИМ. Сервер запускается с --network host, а НЕ с публикацией
# порта. Измерено на стенде: при публикации `-p` пакет доходит до контейнера
# через DNAT даже когда UFW активен и правила для порта нет — Docker его
# обходит. В host-режиме порт слушает сам демон, и UFW им управляет: без
# разрешающего правила пакеты отражаются в журнале, с правилом проходят.
# Публикация означала бы, что меню UFW показывает порт закрытым, пока он открыт.
# ============================================================================

MODE="install"
AWG_PORT=""
AWG_PROFILE="quic"
AWG_VERSION="3.0"

# --------------------------------------------------------------------------
# Пиннинг. Обновляться могут ТРИ вещи независимо: репозиторий, релиз бинарника
# и образы на Docker Hub. Последние публикуются отдельно от GitHub, поэтому
# `latest` может смениться без единого коммита — отследить это можно только по
# digest. Теги в Docker изменяемы, digest — нет, поэтому пинним по digest.
# --------------------------------------------------------------------------
AWG_TOOL_TAG="v0.2.2"
# Тег образов на Docker Hub. Сегодня совпадает с тегом релиза — автор
# выпускает их вместе, — но это две разные поверхности, и однажды они
# разойдутся. Держим отдельной переменной, чтобы проверка обновлений не
# опрашивала реестр по номеру релиза бинарника.
AWG_IMG_TAG="v0.2.2"
AWG_TOOL_SHA="d669dac00879df3beaefdb3526082a946465f83e8bff7c288cd576e27f7bd0e0"
# По образу на версию протокола. Оба из того же семейства, что и 3.0:
# механизм, пиннинг и профиль конфликтов уже проверены на стенде, и вводить
# ради 2.0 второй установщик (DKMS + PPA у wiresock) означало бы удвоить
# поверхность конфликтов ради того, что уже покрыто.
AWG_IMG_20="vaiprog/amnezia-wg-2@sha256:769c2784517196ee001a5819de234c28e4b4820656abc11e37312008ca17fc3e"
AWG_IMG_30="vaiprog/amnezia-wg-3@sha256:091c82084269f2987983468af56980d700b1afdffe35c5dd1b50da79917c5ce7"
AWG_SRV_IMG="$AWG_IMG_30"
AWG_DNS_IMG="vaiprog/amnezia-wg-dns@sha256:0c339b84e7e827982172c26e6bd38a1d99489f9de7e4755e0f24f10a1e441570"
AWG_REL_BASE="https://github.com/Vadim-Khristenko/awg-containers-and-tools/releases/download/${AWG_TOOL_TAG}"

AWG_DIR=/etc/vsm/awg
AWG_CONF=/etc/vsm/awg.conf
AWG_TOOL=/usr/local/bin/awg-tool     # НЕ в /tmp: он очищается при перезагрузке
AWG_DNS_NET=awg-dns-net
AWG_DNS_SUBNET=172.29.172.0/24
AWG_DNS_IP=172.29.172.254            # адрес попадает в каждый выданный конфиг
AWG_TUN_SUBNET=10.99.0.0/24
AWG_SYSCTL=/etc/sysctl.d/99-vsm-awg.conf

log()  { echo -e "\e[1;32m[этап]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m    $*"; }
die()  { echo -e "\e[1;31m[СБОЙ]\e[0m $*" >&2; exit 1; }

# Повторяет команду раз в секунду, пока та не вернёт 0. Двойник функции из
# telemt-stack.sh: установщик самодостаточен и утилиты меню не подключает.
wait_until() {
    local tries="$1"; shift
    local i
    for ((i = 1; i <= tries; i++)); do
        if "$@"; then return 0; fi
        sleep 1
    done
    return 1
}

# Ожидание освобождения блокировки dpkg. Двойник из telemt-stack.sh; возвращает
# 0 и по таймауту — прежнее `return 1` в соседней копии убивало установщик
# молча, и копии приведены к одному поведению.
wait_for_apt() {
    local waited=0 limit="${1:-300}"
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
                /var/lib/apt/lists/lock &>/dev/null; do
        if [ "$waited" -eq 0 ]; then log "жду освобождения apt (идут автообновления)..."; fi
        sleep 3
        waited=$((waited + 3))
        if [ "$waited" -ge "$limit" ]; then
            warn "apt занят дольше ${limit} с, продолжаю без ожидания."
            return 0
        fi
    done
    return 0
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mode)    MODE="$2";        shift 2 ;;
        --port)    AWG_PORT="$2";    shift 2 ;;
        --profile) AWG_PROFILE="$2"; shift 2 ;;
        --awg-version) AWG_VERSION="$2"; shift 2 ;;
        *) die "Неизвестный аргумент: $1" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "Запускай под root."

case "$AWG_VERSION" in
    2.0) AWG_SRV_IMG="$AWG_IMG_20" ;;
    3.0) AWG_SRV_IMG="$AWG_IMG_30" ;;
    *)   die "Версия протокола '${AWG_VERSION}' не поддерживается: только 2.0 или 3.0." ;;
esac

# ---------------------------------------------------------------------------
# Удаление
# ---------------------------------------------------------------------------
if [[ "$MODE" == "uninstall" ]]; then
    log "Удаление AmneziaWG"
    OLD_PORT=""
    if [[ -f "$AWG_CONF" ]]; then
        # shellcheck disable=SC1090
        . "$AWG_CONF"
        OLD_PORT="${AWG_PORT:-}"
    fi
    docker rm -f awg-server awg-dns >/dev/null 2>&1 || true
    docker network rm "$AWG_DNS_NET" >/dev/null 2>&1 || true
    docker volume rm awg-state awg-log >/dev/null 2>&1 || true
    rm -rf "$AWG_DIR"
    rm -f "$AWG_CONF" "$AWG_SYSCTL"
    if [[ -n "$OLD_PORT" ]] && command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${OLD_PORT}/udp" >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true
    # Проверяем фактом: «удалено» по коду возврата rm ничего не значит.
    LEFT="$(docker ps -a --filter 'name=awg-' --format '{{.Names}}' | tr '\n' ' ')" || LEFT=""
    if [[ -n "${LEFT// /}" ]]; then
        die "Остались контейнеры: ${LEFT}"
    fi
    log "AmneziaWG удалён. Стек VSM не тронут."
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------------
log "Этап 1: Docker"
if ! command -v docker >/dev/null 2>&1; then
    wait_for_apt
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
fi
command -v docker >/dev/null 2>&1 || die "Docker не установился."
if ! systemctl is-active --quiet docker; then
    systemctl enable --now docker >/dev/null 2>&1 || true
fi
# Пакет и запущенный демон — разные вещи; проверяем второе.
wait_until 15 docker info >/dev/null 2>&1 || die "Docker установлен, но демон не отвечает. Смотри: systemctl status docker"

# ---------------------------------------------------------------------------
# 2. Выбор порта
# ---------------------------------------------------------------------------
log "Этап 2: порт"
port_busy() {
    local p="$1"
    if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$"; then return 0; fi
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then return 0; fi
    return 1
}
if [[ -z "$AWG_PORT" ]]; then
    for _ in $(seq 30); do
        CAND="$(shuf -i 20000-59999 -n1)"
        if ! port_busy "$CAND"; then AWG_PORT="$CAND"; break; fi
    done
fi
[[ -n "$AWG_PORT" ]] || die "Не удалось подобрать свободный UDP-порт."
[[ "$AWG_PORT" =~ ^[0-9]+$ ]] && [[ "$AWG_PORT" -ge 1024 ]] && [[ "$AWG_PORT" -le 65535 ]] \
    || die "Порт '${AWG_PORT}' невалиден."
# 443/UDP отдельно запрещаем: с 443/TCP он сегодня не конфликтует, но занимает
# порт, на котором панели однажды понадобится HTTP/3.
[[ "$AWG_PORT" != "443" ]] || die "443/UDP занимать нельзя — это порт под HTTP/3 панели."
if port_busy "$AWG_PORT"; then die "Порт ${AWG_PORT} уже занят. Выбери другой."; fi
log "  порт ${AWG_PORT}/udp свободен"

# ---------------------------------------------------------------------------
# 3. Форвардинг — персистентно
#
# Измерено на стенде: после перезагрузки ip_forward=0, при этом контейнеры
# подняты и порт слушает. Снаружи всё выглядит исправным, а трафик клиентов
# маршрутизировать нечем. Постоянной записи не создаёт ни Docker, ни образ:
# `--sysctl` внутри контейнера действует только на его namespace и вдобавок
# несовместим с --network host — Docker отвергает запуск.
#
# DEFAULT_FORWARD_POLICY у UFW по умолчанию DROP. Без правки VPN поднимется и
# будет работать ровно до включения фаервола пунктом меню.
# ---------------------------------------------------------------------------
log "Этап 3: форвардинг"
cat > "$AWG_SYSCTL" <<SYSCTL
# Поставлено VSM для AmneziaWG. Без этой записи после перезагрузки
# ip_forward сбрасывается в 0: контейнеры при этом подняты и порт слушает,
# то есть поломка не видна ничем, кроме отсутствия трафика у клиентов.
net.ipv4.ip_forward = 1
SYSCTL
sysctl -q -p "$AWG_SYSCTL"
FWD="$(sysctl -n net.ipv4.ip_forward)" || FWD=0
[[ "$FWD" == "1" ]] || die "ip_forward не включился."

if [[ -f /etc/default/ufw ]]; then
    if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw; then
        sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        log "  DEFAULT_FORWARD_POLICY переведён в ACCEPT"
        if ufw status 2>/dev/null | grep -q '^Status: active'; then
            ufw reload >/dev/null 2>&1 || true
        fi
    fi
fi
log "  ip_forward=1, запись в ${AWG_SYSCTL}"

# ---------------------------------------------------------------------------
# 4. awg-tool — по тегу, со сверкой официальной суммы
# ---------------------------------------------------------------------------
log "Этап 4: awg-tool ${AWG_TOOL_TAG}"
TOOL_TMP="$(mktemp /tmp/awg-tool.XXXXXX)"
curl -fsSL --max-time 120 -o "$TOOL_TMP" "${AWG_REL_BASE}/awg-tool-x86_64-unknown-linux-gnu" \
    || die "Не удалось скачать awg-tool ${AWG_TOOL_TAG}."
GOT_SHA="$(sha256sum "$TOOL_TMP" | awk '{print $1}')" || GOT_SHA=""
if [[ "$GOT_SHA" != "$AWG_TOOL_SHA" ]]; then
    rm -f "$TOOL_TMP"
    die "Отпечаток awg-tool не совпал. Ожидался ${AWG_TOOL_SHA}, получен ${GOT_SHA:-пусто}. Установка отменена."
fi
install -m 755 "$TOOL_TMP" "$AWG_TOOL"
rm -f "$TOOL_TMP"
log "  ${AWG_TOOL}: $("$AWG_TOOL" --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 5. Образы — по digest
# ---------------------------------------------------------------------------
log "Этап 5: образы"
docker pull -q "$AWG_SRV_IMG" >/dev/null || die "Не удалось получить образ сервера."
docker pull -q "$AWG_DNS_IMG" >/dev/null || die "Не удалось получить образ резолвера."
log "  оба образа получены по digest"

# ---------------------------------------------------------------------------
# 6. Конфигурация сервера
# ---------------------------------------------------------------------------
log "Этап 6: конфигурация AmneziaWG ${AWG_VERSION}"
mkdir -p "$AWG_DIR"
chmod 700 "$AWG_DIR"
SRV_PRIV="$(docker run --rm --entrypoint awg "$AWG_SRV_IMG" genkey)" || die "Не удалось сгенерировать ключ."
# Профиль мимикрии описывает пакет I1 и осмыслен только в 3.0.
if [[ "$AWG_VERSION" == "3.0" ]]; then
    "$AWG_TOOL" gen --version 3.0 --profile "$AWG_PROFILE" > "${AWG_DIR}/params.conf" \
        || die "awg-tool не сгенерировал параметры 3.0."
else
    "$AWG_TOOL" gen --version 2.0 > "${AWG_DIR}/params.conf" \
        || die "awg-tool не сгенерировал параметры 2.0."
    AWG_PROFILE="—"
fi

# Проверяем фактом, что получили запрошенную версию.
#
# Различает их НЕ наличие I1: пакеты I1-I5 есть и в 2.0 — проверено выводом
# awg-tool на обеих версиях. Отличают 3.0 ключи HeaderProtectionKey,
# ContentPaddingAddition и рандомизированные тайминги, которых в 2.0 нет
# вовсе. Ошибка здесь дорогая: образ 2.0 отвергает 3.0-ключи с errno=-22 и
# молча уходит в цикл перезапуска — так и поймали.
V3_KEYS='^(HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime)'
V3_FOUND="$(grep -cE "$V3_KEYS" "${AWG_DIR}/params.conf")" || V3_FOUND=0
if [[ "$AWG_VERSION" == "3.0" ]] && [[ "${V3_FOUND:-0}" -eq 0 ]]; then
    die "Запрошена 3.0, но в параметрах нет ключей 3.0. Проверь awg-tool."
fi
if [[ "$AWG_VERSION" == "2.0" ]] && [[ "${V3_FOUND:-0}" -ne 0 ]]; then
    die "Запрошена 2.0, но в параметрах ${V3_FOUND} ключей 3.0 — образ 2.0 их отвергнет. Проверь awg-tool."
fi

( umask 077
  { echo "[Interface]"
    echo "PrivateKey = ${SRV_PRIV}"
    echo "Address = ${AWG_TUN_SUBNET%.*/*}.1/24"
    echo "ListenPort = ${AWG_PORT}"
    cat "${AWG_DIR}/params.conf"
  } > "${AWG_DIR}/server.conf" )
chmod 600 "${AWG_DIR}/server.conf" "${AWG_DIR}/params.conf"
log "  server.conf готов: версия ${AWG_VERSION}, профиль мимикрии ${AWG_PROFILE}"

# ---------------------------------------------------------------------------
# 7. Резолвер
#
# cap_drop ALL, как в примере автора, не работает: образ стартует от root, а
# unbound.conf в нём требует сброса привилегий на пользователя unbound. Без
# SETUID/SETGID это «unable to set group id: Operation not permitted» и вечный
# цикл перезапуска — проверено на стенде, восемь падений подряд. Возвращаем
# ровно две возможности, остальное остаётся снятым.
# ---------------------------------------------------------------------------
log "Этап 7: резолвер"
docker network create --subnet "$AWG_DNS_SUBNET" "$AWG_DNS_NET" >/dev/null 2>&1 || true
docker rm -f awg-dns >/dev/null 2>&1 || true
docker run -d --name awg-dns --restart unless-stopped \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID \
    --read-only --tmpfs /var/log/unbound \
    --network "$AWG_DNS_NET" --ip "$AWG_DNS_IP" "$AWG_DNS_IMG" >/dev/null \
    || die "Резолвер не запустился."

# ---------------------------------------------------------------------------
# 8. Сервер в host-режиме
# ---------------------------------------------------------------------------
log "Этап 8: сервер"
docker rm -f awg-server >/dev/null 2>&1 || true
docker run -d --name awg-server --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun \
    -v "${AWG_DIR}/server.conf:/etc/amnezia/awg/awg0.conf:ro" \
    -v awg-state:/var/lib/awg -v awg-log:/var/log/awg \
    "$AWG_SRV_IMG" >/dev/null \
    || die "Сервер не запустился."

# ---------------------------------------------------------------------------
# 9. UFW
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${AWG_PORT}/udp" >/dev/null 2>&1 || true
    log "Этап 9: правило UFW для ${AWG_PORT}/udp добавлено"
fi

# ---------------------------------------------------------------------------
# 10. Приёмка ПО ФАКТУ
#
# «Контейнер запущен» ничего не значит: он может крутиться в цикле рестарта, а
# порт слушать никто. Проверяем то, что должно быть верно на работающем узле.
# ---------------------------------------------------------------------------
log "Этап 10: проверка"
awg_running()  { [[ "$(docker inspect -f '{{.State.Running}}' awg-server 2>/dev/null)" == "true" ]]; }
awg_listens()  { ss -lunp 2>/dev/null | grep -q ":${AWG_PORT}\b"; }
wait_until 30 awg_running || die "Контейнер сервера не поднялся. Смотри: docker logs awg-server"
wait_until 30 awg_listens || die "Порт ${AWG_PORT}/udp никто не слушает. Смотри: docker logs awg-server"

if ! docker logs awg-server 2>&1 | grep -q 'config-applied'; then
    die "Демон не принял конфигурацию ${AWG_VERSION}. Смотри: docker logs awg-server"
fi
RESTARTS="$(docker inspect -f '{{.RestartCount}}' awg-server 2>/dev/null)" || RESTARTS=0
if [[ "${RESTARTS:-0}" -gt 0 ]]; then
    warn "Сервер перезапускался ${RESTARTS} раз — смотри docker logs awg-server"
fi
DNS_OK=1
if ! wait_until 20 sh -c "docker inspect -f '{{.State.Running}}' awg-dns 2>/dev/null | grep -q true"; then
    warn "Резолвер не поднялся: клиентам придётся указывать свой DNS."
    DNS_OK=0
fi

( umask 077; cat > "$AWG_CONF" <<CONF
# AmneziaWG, поставлен VSM. Пиннинг: обновляться могут репозиторий, релиз
# бинарника и образы на Docker Hub — независимо друг от друга. Образы
# публикуются отдельно от GitHub, поэтому отслеживаются по digest.
AWG_PORT=${AWG_PORT}
AWG_VERSION=${AWG_VERSION}
AWG_PROFILE=${AWG_PROFILE}
AWG_TOOL_TAG=${AWG_TOOL_TAG}
AWG_TOOL_SHA=${AWG_TOOL_SHA}
AWG_IMG_TAG=${AWG_IMG_TAG}
AWG_SRV_IMG=${AWG_SRV_IMG}
AWG_DNS_IMG=${AWG_DNS_IMG}
AWG_DNS_IP=${AWG_DNS_IP}
AWG_TUN_SUBNET=${AWG_TUN_SUBNET}
AWG_DNS_OK=${DNS_OK}
CONF
)
chmod 600 "$AWG_CONF"

cat <<SUMMARY

════════════════════════════════════════════════════════════════
AmneziaWG ${AWG_VERSION} работает. Порт ${AWG_PORT}/udp, профиль мимикрии ${AWG_PROFILE}.

Стек VSM не тронут: сервер поднят в host-режиме, порт слушает сам демон,
и правилами UFW он управляется как обычный порт.

Клиенты — пункт меню «Клиенты AmneziaWG» либо вручную:
  docker exec -e AWG_ENDPOINT=<домен-или-IP>:${AWG_PORT} awg-server awg-peer add имя

Настройки записаны в ${AWG_CONF}, конфиг сервера в ${AWG_DIR}.
════════════════════════════════════════════════════════════════
SUMMARY
