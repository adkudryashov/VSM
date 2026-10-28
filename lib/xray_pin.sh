# shellcheck shell=bash
# Ядро Xray в 3x-ui — закреплённой версии, а не той, что привезла панель.
#
# ЗАЧЕМ. 3x-ui 3.11.0 приезжает с Xray 26.10.21, и с ним REALITY для mihomo
# 1.19.31 не проходил: 503 три раза из трёх, остальные пять подключений шли
# (HostUp, 28.10.2026). С 26.7.28 — 6/6 дважды подряд. Причину по выпускам
# Xray установить не удалось, поэтому закрепляем проверенное ядро, а не чиним.
#
# Порядок: скачать архив XTLS → сверить SHA-256 (для закреплённой версии — со
# своей записью ниже, для любой другой — с файлом .dgst того же выпуска) →
# проверить новым ядром ТЕКУЩИЙ конфиг панели (`run -test`) → копия старого в
# /var/backups/vsm/xray → подмена через mv → перезапуск x-ui → версия фактом.
# Не поднялось — старое ядро обратно.
#
# `x-ui update` и смена версии Xray в панели вернут ядро панели — после них
# повторить: меню не нужно, хватит `xray_pin_apply` или переустановки стека.

XRAY_PIN_VERSION="${XRAY_PIN_VERSION-26.7.28}"
XRAY_PIN_BIN_DIR="${XRAY_PIN_BIN_DIR:-/usr/local/x-ui/bin}"
XRAY_PIN_BACKUP_DIR="${XRAY_PIN_BACKUP_DIR:-/var/backups/vsm/xray}"
XRAY_PIN_URL="${XRAY_PIN_URL:-https://github.com/XTLS/Xray-core/releases/download}"
XRAY_PIN_WAIT="${XRAY_PIN_WAIT:-30}"

# SHA-256 архивов закреплённой версии, сверено 28.10.2026 по .dgst выпуска и
# по полю digest в API GitHub.
declare -gA XRAY_PIN_SHA256=(
    [26.7.28/64]=8195d909f1109b8f3d99eefe401a3c451d7bf4af71f24d3815420f77e5dd2a40
    [26.7.28/arm64-v8a]=f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501
)

_xp_fail() { echo -e "${RED:-}❌ $*${NC:-}" >&2; return 1; }

# Имя архива XTLS и имя бинарника в каталоге 3x-ui для этой машины.
_xp_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "64 amd64" ;;
        aarch64|arm64) echo "arm64-v8a arm64" ;;
        *) return 1 ;;
    esac
}

# Версия ядра, которое сейчас лежит в каталоге панели («нет» — ядра нет).
xray_pin_state() {
    local arch bin
    arch="$(_xp_arch)" || { echo "архитектура не поддерживается"; return 0; }
    bin="$XRAY_PIN_BIN_DIR/xray-linux-${arch#* }"
    [ -x "$bin" ] || { echo "нет"; return 0; }
    "$bin" version 2>/dev/null | awk 'NR==1 {print $2}'
}

# По полной команде, а не по имени: имя процесса ядро режет до 15 символов
# («xray-linux-amd6»), и `pgrep -x xray-linux-amd64` не нашёл бы ничего.
# x-ui запускает его относительным путём: «bin/xray-linux-amd64 -c …». Якорь
# ^ — чтобы не находить собственную оболочку, в чьей команде есть это имя.
_xp_running() { pgrep -f "^([^ ]*/)?xray-linux-${1}( |$)" >/dev/null 2>&1; }

# Перезапустить панель и дождаться ядра нужной версии.
_xp_restart_wait() {
    local want="$1" xarch="$2" i
    systemctl restart x-ui || return 1
    for ((i = 0; i < XRAY_PIN_WAIT; i++)); do
        if systemctl is-active --quiet x-ui && _xp_running "$xarch" \
           && [ "$(xray_pin_state)" = "$want" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

xray_pin_apply() {
    local want="${1:-$XRAY_PIN_VERSION}" arch zarch xarch bin cur tmp zip sum expect backup
    want="${want#v}"
    [ -n "$want" ] && [ "$want" != "latest" ] || return 0
    arch="$(_xp_arch)" || { _xp_fail "Xray: архитектура $(uname -m) не поддерживается"; return 1; }
    zarch="${arch% *}"; xarch="${arch#* }"
    bin="$XRAY_PIN_BIN_DIR/xray-linux-$xarch"
    [ -x "$bin" ] || { _xp_fail "Xray: нет $bin — 3x-ui не установлена?"; return 1; }
    cur="$(xray_pin_state)"
    [ "$cur" = "$want" ] && return 0

    tmp="$(mktemp -d)" || return 1
    zip="$tmp/xray.zip"
    if ! curl -fsSL --retry 3 --max-time 120 "$XRAY_PIN_URL/v$want/Xray-linux-$zarch.zip" -o "$zip"; then
        rm -rf "$tmp"; _xp_fail "Xray $want: архив не скачался"; return 1
    fi
    expect="${XRAY_PIN_SHA256[$want/$zarch]:-}"
    if [ -z "$expect" ]; then
        expect="$(curl -fsSL --retry 3 --max-time 30 "$XRAY_PIN_URL/v$want/Xray-linux-$zarch.zip.dgst" \
            | grep -oP '^SHA2-256=\s*\K[0-9a-f]{64}')" || expect=""
    fi
    sum="$(sha256sum "$zip" | awk '{print $1}')"
    if [ -z "$expect" ] || [ "$sum" != "$expect" ]; then
        rm -rf "$tmp"; _xp_fail "Xray $want: сумма архива не сошлась (${sum:0:12}… против ${expect:0:12}…)"; return 1
    fi
    # unzip в Ubuntu по умолчанию нет — распаковывает python3.
    if ! python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("xray", sys.argv[2])' \
            "$zip" "$tmp" || [ ! -s "$tmp/xray" ]; then
        rm -rf "$tmp"; _xp_fail "Xray $want: не распаковался"; return 1
    fi
    chmod 755 "$tmp/xray"
    if [ "$("$tmp/xray" version 2>/dev/null | awk 'NR==1 {print $2}')" != "$want" ]; then
        rm -rf "$tmp"; _xp_fail "Xray $want: в архиве другая версия"; return 1
    fi
    # Конфиг уже собран панелью под её ядро: другое ядро может его не принять,
    # и тогда x-ui поднимется без единого подключения.
    if [ -r "$XRAY_PIN_BIN_DIR/config.json" ] \
       && ! XRAY_LOCATION_ASSET="$XRAY_PIN_BIN_DIR" "$tmp/xray" run -test -c "$XRAY_PIN_BIN_DIR/config.json" >/dev/null 2>&1; then
        rm -rf "$tmp"; _xp_fail "Xray $want не принимает конфиг панели — ядро оставлено $cur"; return 1
    fi

    mkdir -p "$XRAY_PIN_BACKUP_DIR" && chmod 700 "$XRAY_PIN_BACKUP_DIR" || { rm -rf "$tmp"; return 1; }
    backup="$XRAY_PIN_BACKUP_DIR/xray-linux-$xarch.$cur"
    cp -p "$bin" "$backup" || { rm -rf "$tmp"; _xp_fail "Xray: не сохранить копию ядра"; return 1; }
    # Через mv в том же каталоге: cp поверх работающего бинарника падает
    # «Text file busy», а rename не трогает файл, который исполняется.
    install -m 755 "$tmp/xray" "$bin.vsm-new" && mv -f "$bin.vsm-new" "$bin"
    rm -rf "$tmp"

    if _xp_restart_wait "$want" "$xarch"; then
        return 0
    fi
    install -m 755 "$backup" "$bin.vsm-new" && mv -f "$bin.vsm-new" "$bin"
    _xp_restart_wait "$cur" "$xarch" || true
    _xp_fail "Xray $want не поднялся — возвращено $cur (копия: $backup)"
    return 1
}
