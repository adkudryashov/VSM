#!/usr/bin/env bash
# ============================================================================
# Обновление telemt: скачать, сверить, прогнать на нашем конфиге, заменить,
# проверить фактом, при отказе вернуть прежний.
#
#   telemt-update.sh --check              что стоит, что вышло, можно ли ставить
#   telemt-update.sh                      обновить до последней (спросит)
#   telemt-update.sh --version 3.5.7      поставить именно эту (и назад тоже)
#   telemt-update.sh --rollback           вернуть версию до последнего обновления
#   --yes                                 не спрашивать подтверждения
#
# Окружение (для проверок, не для жизни):
#   TELEMT_CONF=<путь>   конфиг для ПРОБНОГО запуска вместо боевого
#
# ПОЧЕМУ ТАК, А НЕ «СКАЧАТЬ И ПОДМЕНИТЬ». Два обновления подряд telemt
# обновлялся руками, и оба раза подмена вслепую сломала бы прокси:
#
#   3.5.6 сменил конверт статуса моста WEB, и родной клиент Telegram на macOS
#   перестал подключаться. Откатили в 3.5.7. Отсюда список плохих версий.
#
#   Каждая версия проверяет конфиг по-своему и при несогласии просто не
#   стартует — прокси ложится в момент перезапуска. Пример замерен этим же
#   скриптом: 3.5.2 не знает carrier = "websocket-lanes" и отказывается
#   стартовать на нашем конфиге. Отсюда пробный запуск.
#
#   (Раньше здесь и в docs/DECISIONS.md было написано, что 3.5.7 ВВЁЛ проверки
#   public_addr на 443, reuse_allow и пустого web_trusted_proxy_cidrs. Неверно:
#   прогон 19.09.2026 показал, что все три отвергает уже 3.5.5.)
#
# ПРОБНЫЙ ЗАПУСК. Новый бинарь стартует рядом с работающим, на КОПИИ нашего
# конфига, где все слушающие адреса перенесены на свободные порты петли, а
# каталог данных — во временный. Всё остальное, включая то, что новая версия
# может отвергнуть, остаётся как есть. Если ответил API — конфиг принят.
#
# Контрольный случай встроен: сначала пробный запуск делает ТЕКУЩАЯ версия.
# Не поднялась она — значит, сломан сам пробный запуск на этом конфиге, и
# отказ новой версии ничего бы не значил. Тогда обновление не делаем вовсе.
#
# Выбор сборки повторяет официальный установщик telemt: x86_64-v3 при AVX2 и
# BMI2, иначе обычная x86_64; musl или gnu — по системе.
# ============================================================================
set -euo pipefail

REPO="telemt/telemt"
CONF="/etc/telemt/telemt.toml"
TRIAL_CONF="${TELEMT_CONF:-$CONF}"
DATA_DIR="/opt/telemt"
BACKUP_DIR="/var/backups/vsm/telemt"

# Версии, которые ставить нельзя, и почему. Причину печатаем человеку.
declare -A BAD_VERSIONS=(
    [3.5.6]="ломает родной клиент Telegram на macOS: сменён конверт статуса моста WEB (исправлено в 3.5.7, PR 923)"
)

R='\e[1;31m'; G='\e[1;32m'; Y='\e[1;33m'; B='\e[1;34m'; N='\e[0m'
say()  { echo -e "$*"; }
ok()   { echo -e "${G}✓${N}  $*"; }
warn() { echo -e "${Y}!${N}  $*"; }
die()  { echo -e "${R}✗  $*${N}" >&2; exit 1; }

# Журнал движка может содержать секреты пользователей и ссылки с ними.
# Строки не режем — обрезка уже раз оставила кусок секрета под порогом маски.
mask() { sed -E 's/[0-9a-fA-F]{16,}/<скрыт>/g; s/(secret=)[^&[:space:]]+/\1<скрыт>/g'; }

ACTION="update"; WANT=""; YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    ACTION="check"; shift ;;
        --rollback) ACTION="rollback"; shift ;;
        --version)  WANT="${2:-}"; WANT="${WANT#v}"; shift 2 ;;
        --yes|-y)   YES=1; shift ;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
        *) die "Неизвестный аргумент: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Нужен root."

# Путь к бинарю берём у службы: установщик telemt кладёт его в /usr/bin, а
# ручная установка могла положить куда угодно.
BIN="$(systemctl show telemt -p ExecStart --value 2>/dev/null | sed -nE 's/.*path=([^ ;]+).*/\1/p')"
[[ -n "$BIN" ]] || BIN="$(command -v telemt || true)"
[[ -x "$BIN" ]] || die "telemt не найден. Сначала установите стек."
[[ -r "$CONF" ]] || die "Нет конфига $CONF."

# `|| true`: при pipefail пустой grep уронил бы весь скрипт молча, set -e.
version_of() { { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; } || true; }

# Адрес API из секции [server.api]. По нему судим, что движок поднялся.
api_addr() {
    awk '/^\[/{s=$0} s=="[server.api]" && /^[[:space:]]*listen[[:space:]]*=/{
        gsub(/.*=[[:space:]]*"|".*/, ""); print; exit }' "$1"
}

# Поднялся ли движок: API ответил хоть чем-то. Любой код, кроме «нет
# соединения», значит, что процесс стоит и конфиг принят — API может быть и
# закрыт заголовком авторизации, это не наше дело.
api_up() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$1/v1/health" 2>/dev/null) || true
    [[ -n "$code" && "$code" != "000" ]]
}

asset_name() {
    local arch libc="gnu" m; m="$(uname -m)"
    case "$m" in
        x86_64|amd64)
            if grep -q avx2 /proc/cpuinfo && grep -q bmi2 /proc/cpuinfo; then arch="x86_64-v3"; else arch="x86_64"; fi ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "Архитектура $m не поддерживается сборками telemt." ;;
    esac
    if ls /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.* >/dev/null 2>&1 \
       || (ldd --version 2>&1 || true) | grep -qi musl; then
        libc="musl"
    fi
    echo "telemt-${arch}-linux-${libc}.tar.gz"
}

gh_api() { curl -fsSL --connect-timeout 20 --retry 2 --max-time 30 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/$1"; }

latest_version() {
    gh_api releases/latest | jq -r '.tag_name // empty' | sed 's/^v//'
}

# Скачивает сборку версии $1 в каталог $2 и проверяет её.
# Сумму берём из файла .sha256 рядом с архивом, а если он не пришёл — из
# отпечатка, который GitHub публикует у самого файла. Без сверки не ставим:
# бинарь работает с правами на порт 443 и видит весь трафик прокси.
fetch() {
    local ver="$1" dir="$2" asset want have url
    asset="$(asset_name)"
    url="https://github.com/$REPO/releases/download/$ver/$asset"
    say "${B}Скачиваю${N} $asset ($ver)…"
    if ! curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 3 --max-time 300 -o "$dir/$asset" "$url"; then
        if [[ "$asset" == *x86_64-v3* ]]; then
            asset="${asset/x86_64-v3/x86_64}"; url="https://github.com/$REPO/releases/download/$ver/$asset"
            warn "Сборки x86_64-v3 нет, беру обычную x86_64."
            curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 3 --max-time 300 -o "$dir/$asset" "$url" || die "Не скачалось: $url"
        else
            die "Не скачалось: $url"
        fi
    fi
    want="$(curl -fsSL --connect-timeout 20 --retry 2 --max-time 30 "$url.sha256" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)" || true
    if [[ -z "$want" ]]; then
        want="$(gh_api "releases/tags/$ver" | jq -r --arg a "$asset" \
            '.assets[] | select(.name == $a) | .digest // empty' | sed 's/^sha256://')" || true
    fi
    [[ -n "$want" ]] || die "Контрольную сумму $asset получить не удалось — без сверки не ставлю."
    have="$(sha256sum "$dir/$asset" | cut -c1-64)"
    [[ "$want" == "$have" ]] || die "Сумма не совпала: ждали $want, получили $have."
    ok "Контрольная сумма совпала."
    tar -xzf "$dir/$asset" -C "$dir"
    [[ -x "$dir/telemt" ]] || die "В архиве нет исполняемого telemt."
    local got; got="$(version_of "$dir/telemt")"
    [[ "$got" == "$ver" ]] || die "Архив $ver, а бинарь называет себя «$got»."
}

free_port() {
    local p
    for _ in $(seq 1 200); do
        p=$(( 20000 + RANDOM % 10000 ))
        if ! ss -Hltn "sport = :$p" | grep -q . && ! grep -qx "$p" "$USED_PORTS" 2>/dev/null; then
            echo "$p" >> "$USED_PORTS"; echo "$p"; return
        fi
    done
    die "Не нашёл свободного порта для пробного запуска."
}

# Копия конфига, где всё, что слушает, переехало на свободные порты петли.
# Меняем ТОЛЬКО адреса прослушивания. public_addr, домены, маску и прочее не
# трогаем: именно на них новая версия и может споткнуться, это и проверяем.
trial_config() {
    local src="$1" dst="$2" line sec="" out=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*\[ ]]; then sec="${line//[[:space:]]/}"; fi
        case "$sec" in
            "[[server.listeners]]"|"[server]")
                if [[ "$line" =~ ^[[:space:]]*port[[:space:]]*= ]]; then line="port = $(free_port)"
                elif [[ "$line" =~ ^[[:space:]]*(ip|listen_addr_ipv4)[[:space:]]*= ]]; then line="${BASH_REMATCH[1]} = \"127.0.0.1\""
                elif [[ "$line" =~ ^[[:space:]]*listen_addr_ipv6[[:space:]]*= ]]; then line="# $line"
                elif [[ "$line" =~ ^[[:space:]]*metrics_listen[[:space:]]*= ]]; then line="metrics_listen = \"127.0.0.1:$(free_port)\""
                elif [[ "$line" =~ ^[[:space:]]*metrics_port[[:space:]]*= ]]; then line="metrics_port = $(free_port)"
                elif [[ "$line" =~ ^[[:space:]]*listen_unix_sock[[:space:]]*= ]]; then line="listen_unix_sock = \"$TRIAL_DIR/telemt.sock\""
                fi ;;
            "[server.api]")
                if [[ "$line" =~ ^[[:space:]]*listen[[:space:]]*= ]]; then line="listen = \"127.0.0.1:$(free_port)\""; fi ;;
        esac
        out+=("$line")
    done < "$src"
    printf '%s\n' "${out[@]}" > "$dst"
}

# Пробный запуск бинаря $1. Возвращает 0, если движок поднялся на копии конфига.
trial() {
    local bin="$1" label="$2"
    local cfg="$TRIAL_DIR/trial-$label.toml" data="$TRIAL_DIR/data-$label" api pid i
    trial_config "$TRIAL_CONF" "$cfg"
    api="$(api_addr "$cfg")"
    [[ -n "$api" ]] || die "В конфиге нет [server.api] listen — поднялся ли движок, узнать нечем."
    mkdir -p "$data"; cp -a "$DATA_DIR/." "$data/" 2>/dev/null || true
    "$bin" run "$cfg" --data-path "$data" > "$TRIAL_DIR/trial-$label.log" 2>&1 &
    pid=$!
    for i in $(seq 1 30); do
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        if api_up "$api"; then
            sleep 3
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
                return 0
            fi
            break
        fi
        sleep 1
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    say "${R}Движок $label не поднялся на нашем конфиге. Из его журнала:${N}"
    grep -iE 'error|invalid|must|fail|panic' "$TRIAL_DIR/trial-$label.log" | head -15 | mask || true
    return 1
}

# Перезапуск и проверка фактом: служба активна, API отвечает, бинарь той версии.
restart_verified() {
    local ver="$1" api i
    api="$(api_addr "$CONF")"
    systemctl restart telemt || true
    for i in $(seq 1 40); do
        if systemctl is-active --quiet telemt && api_up "$api"; then
            [[ "$(version_of "$BIN")" == "$ver" ]] && return 0
        fi
        sleep 1
    done
    return 1
}

install_bin() {
    local src="$1" tmp="$BIN.vsm-new"
    install -m 755 -o root -g root "$src" "$tmp"
    mv -f "$tmp" "$BIN"
}

confirm() {
    [[ $YES -eq 1 ]] && return 0
    local a; read -r -p "$(echo -e "${Y}$1${N}")" a
    [[ "$a" == "$2" ]]
}

CUR="$(version_of "$BIN")"
[[ -n "$CUR" ]] || die "Не понял версию установленного telemt."

# --- откат -------------------------------------------------------------------
if [[ "$ACTION" == "rollback" ]]; then
    # Какую копию возвращать, записано явно при замене. Не по времени файла:
    # cp -a сохраняет время УСТАНОВКИ бинаря, а не время копирования, и после
    # пары откатов «самая свежая» копия оказалась бы не той.
    prev="$(cat "$BACKUP_DIR/previous" 2>/dev/null || true)"
    [[ -n "$prev" && -x "$prev" ]] || die "Не записано, к чему откатываться: замен через это меню ещё не было."
    pver="$(version_of "$prev")"
    say "Сейчас ${B}$CUR${N}, копия — ${B}$pver${N} (${prev##*/})."
    confirm "Вернуть $pver? Введите ОТКАТ: " "ОТКАТ" || { say "Отменено."; exit 0; }
    cp -a "$BIN" "$BACKUP_DIR/telemt-$CUR.before-rollback"
    install_bin "$prev"
    if restart_verified "$pver"; then
        # Повторный откат вернёт то, от чего откатились, — то есть отменит этот.
        echo "$BACKUP_DIR/telemt-$CUR.before-rollback" > "$BACKUP_DIR/previous"
        ok "Возвращён $pver, движок отвечает."
        exit 0
    fi
    die "После отката движок не поднялся. Смотрите: journalctl -u telemt -n 50"
fi

# --- что ставить -------------------------------------------------------------
LATEST="$(latest_version || true)"
TARGET="${WANT:-$LATEST}"
[[ -n "$TARGET" ]] || die "Не удалось узнать последнюю версию у GitHub."

say "Установлена: ${B}$CUR${N}    Последняя: ${B}${LATEST:-не узнал}${N}"
if [[ -n "${BAD_VERSIONS[$TARGET]:-}" ]]; then
    say "${R}Версию $TARGET ставить нельзя:${N} ${BAD_VERSIONS[$TARGET]}."
    [[ "$ACTION" == "check" ]] && exit 0
    exit 2
fi
if [[ "$TARGET" == "$CUR" ]]; then
    ok "Стоит $CUR — обновлять нечего."
    exit 0
fi
downgrade=0
[[ "$(printf '%s\n' "$CUR" "$TARGET" | sort -V | head -1)" == "$TARGET" ]] && downgrade=1
if [[ "$ACTION" == "check" ]]; then
    if [[ $downgrade -eq 1 ]]; then say "Запрошенная $TARGET СТАРШЕ установленной."; else say "Доступно обновление до ${G}$TARGET${N}."; fi
    say "Заметки к выпуску: https://github.com/$REPO/releases/tag/$TARGET"
    exit 0
fi

TRIAL_DIR="$(mktemp -d /tmp/vsm-telemt-update.XXXXXX)"
USED_PORTS="$TRIAL_DIR/ports"
trap 'rm -rf "$TRIAL_DIR"' EXIT

fetch "$TARGET" "$TRIAL_DIR"

say "${B}Пробный запуск текущей $CUR${N} (контрольный: проверяем саму проверку)…"
trial "$BIN" "$CUR" || die "Пробный запуск не работает даже с текущей версией — проверить новую нечем. Ничего не менял."
ok "Текущая поднялась на копии конфига."

say "${B}Пробный запуск новой $TARGET${N} на том же конфиге…"
trial "$TRIAL_DIR/telemt" "$TARGET" || die "Версия $TARGET не принимает наш конфиг (причина выше). Ничего не менял, работает $CUR."
ok "$TARGET принимает наш конфиг."

say ""
say "Заменю $CUR → ${G}$TARGET${N} и перезапущу telemt."
say "Открытые соединения клиентов оборвутся, клиенты переподключатся сами за секунды."
[[ $downgrade -eq 1 ]] && warn "Это откат на более старую версию."
confirm "Введите ОБНОВИТЬ для продолжения: " "ОБНОВИТЬ" || { say "Отменено. Ничего не менял."; exit 0; }

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
cp -a "$BIN" "$BACKUP_DIR/telemt-$CUR"
cp -a "$CONF" "$BACKUP_DIR/telemt.toml-$CUR-$(date +%Y%m%d-%H%M%S)"
install_bin "$TRIAL_DIR/telemt"

if restart_verified "$TARGET"; then
    echo "$BACKUP_DIR/telemt-$CUR" > "$BACKUP_DIR/previous"
    ok "telemt $TARGET работает: служба активна, API отвечает."
    say "Прежняя версия сохранена: $BACKUP_DIR/telemt-$CUR (вернуть — «Откатить обновление telemt»)."
    exit 0
fi

warn "После замены движок не поднялся. Возвращаю $CUR…"
journalctl -u telemt -n 30 --no-pager 2>/dev/null | grep -iE 'error|invalid|must|fail|panic' | head -10 | mask || true
install_bin "$BACKUP_DIR/telemt-$CUR"
if restart_verified "$CUR"; then
    die "Обновление не удалось, возвращена $CUR — прокси работает как раньше."
fi
die "Обновление не удалось, и прежняя $CUR тоже не поднялась. Смотрите: journalctl -u telemt -n 50"
