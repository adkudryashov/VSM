#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# УСТАНОВЩИК СТЕКА: 3x-ui-pro + telemt + telemt_panel
#
# Встроен в VSM (пункт "telemt / MTProto"), запускается локально.
#
# Два режима работы (--mode):
#   full  — ставит 3x-ui-pro с нуля, затем telemt и telemt_panel.
#           ВНИМАНИЕ: установщик панели стирает существующую /etc/x-ui
#           (БД, инбаунды, пользователей).
#   addon — ставит только telemt и telemt_panel поверх УЖЕ установленной
#           3x-ui-pro, ничего в панели не трогая. Режим по умолчанию.
#
# ОБЯЗАТЕЛЬНЫЕ ПЕРЕМЕННЫЕ:
#   DOMAIN_PANEL    — домен панели 3x-ui-pro, он же self-SNI цель для telemt
#   DOMAIN_REALITY  — домен REALITY SNI-роутинга, он же домен telemt_panel
#                     (обязан отличаться от DOMAIN_PANEL)
#
# ОПЦИОНАЛЬНЫЕ:
#   TELEMT_PORT=8444        публичный порт telemt
#   TELEMT_MASK_PORT=7444   локальный порт self-SNI vhost
#   PANEL_PORT=9444         публичный порт telemt_panel
#   TELEMT_SECRET=<hex32>   MTProto-секрет (по умолчанию генерируется;
#                           при повторном запуске переиспользуется старый)
#   PANEL_ADMIN_USER=admin
#   PANEL_ADMIN_PASS=<...>  (по умолчанию генерируется)
#   XUI_VERSION=<3.6.0>     поставить ИМЕННО эту версию 3x-ui вместо последней
# ============================================================================
#
# ПРО XUI_VERSION. Пусто по умолчанию, и это не забывчивость: проект решил
# версии не фиксировать, потому что пиннинг отрезает и исправления
# безопасности (docs/DECISIONS.md). Ставим то же, что получит любой человек по
# README, — иначе проверяем не то, чем пользуются.
#
# Но откат нужен наготове. 3x-ui 3.7.0 вышел 24.08.2026 и требует миграции
# схемы базы при первом старте, а установщик mozaroc пишет в эту базу напрямую
# (INSERT INTO inbounds/hosts с явными списками колонок) и последний раз
# правился 06.08.2026 — за 18 дней до релиза. Одну схемную правку он обходит
# грамотно, щупая базу через PRAGMA table_info, но это защита от известного
# изменения, а не от новых.
#
# Если панель не встанет — XUI_VERSION=3.6.0 возвращает последнюю версию, на
# которой стек проходил приёмку целиком. Это флаг на такой случай, а не новое
# умолчание.

STACK_CONF_DIR="/etc/vsm"
STACK_CONF="$STACK_CONF_DIR/telemt.conf"
STACK_CREDS="$STACK_CONF_DIR/telemt-credentials.txt"

MODE="addon"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-addon}"; shift 2 ;;
        *)      shift ;;
    esac
done
case "$MODE" in full|addon) ;; *) MODE="addon" ;; esac

log()  { echo -e "\e[1;32m[этап]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m    $*"; }
die()  { echo -e "\e[1;31m[СБОЙ]\e[0m $*" >&2; exit 1; }
verify_or_die() { "$@" || die "проверка не прошла: $*"; }

# Отпечаток стороннего установщика: запомнить и громко сказать, если изменился.
#
# Двойник upstream_fingerprint из lib/deps.sh: этот скрипт самодостаточен и
# утилиты меню не подключает — как и с wait_for_apt, поведение копий обязано
# совпадать. Но копия здесь ОДНА на оба установщика, а не по копии на каждый:
# раньше эти тридцать строк стояли в теле этапа 1, и добавление второго
# установщика означало бы третью реализацию одного и того же.
#
# Нужно потому, что оба файла берутся с ветки main без пиннинга и выполняются
# от root. Автор 3x-ui-pro уже удалял разбор аргумента, который мы передавали,
# а его ветка `*) shift 1` проглатывает неизвестный флаг молча — узнали не от
# кода.
#
# ЭТО ПРЕДУПРЕЖДЕНИЕ, А НЕ ЗАПРЕТ: установка продолжается в любом случае.
# Фиксация версий отрезала бы и исправления безопасности, а решать, доверять ли
# новому файлу, всё равно человеку.
UPSTREAM_FP_FILE=/etc/vsm/upstream.sha256
fingerprint_upstream() {
    local url="$1" file="$2" sha old="" tmp now
    now="$(date '+%F')"
    sha="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')" || sha=""
    [[ -n "$sha" ]] || { warn "Не удалось посчитать отпечаток $url — сверка пропущена."; return 0; }

    mkdir -p /etc/vsm
    if [[ -f "$UPSTREAM_FP_FILE" ]]; then
        # Построчно и сравнением поля целиком, а не грепом: в адресе есть точки
        # и слэши, а для регулярки точка — любой символ, и похожий адрес
        # соседнего проекта совпал бы заодно.
        local u h
        while read -r u h _; do
            [[ "$u" == "$url" ]] && old="$h"
        done < "$UPSTREAM_FP_FILE"
    fi

    if [[ -z "$old" ]]; then
        ( umask 077; printf '%s %s %s\n' "$url" "$sha" "$now" >> "$UPSTREAM_FP_FILE" )
        return 0
    fi
    [[ "$old" == "$sha" ]] && return 0

    warn "Сторонний установщик изменился с прошлого запуска:"
    warn "  $url"
    warn "  было  ${old}"
    warn "  стало ${sha}"
    warn "  Он выполняется от root, и аргументы могли смениться."
    # Запоминаем новый сразу: иначе предупреждение повторялось бы при каждом
    # запуске и очень быстро перестало бы читаться.
    tmp="$(mktemp "${UPSTREAM_FP_FILE}.XXXXXX")" || return 0
    awk -v u="$url" '$1 != u' "$UPSTREAM_FP_FILE" > "$tmp" 2>/dev/null || true
    printf '%s %s %s\n' "$url" "$sha" "$now" >> "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$UPSTREAM_FP_FILE"
    return 0
}

# Повторяет команду раз в секунду, пока та не вернёт 0. Нужна там, где systemd
# уже отдал "active", а сама служба ещё дозапускается: фиксированный sleep либо
# тормозит установку, либо не дожидается — и то и другое мы поймали в бою.
wait_until() {
    local tries="$1"; shift
    local i
    for ((i = 1; i <= tries; i++)); do
        if "$@"; then return 0; fi
        sleep 1
    done
    return 1
}

# Ожидание освобождения блокировки dpkg. Двойник функции из
# lib/common.sh: этот скрипт самодостаточен и утилиты меню не
# подключает, поэтому небольшое повторение здесь дешевле связности.
#
# Нужно потому, что стек ставят на только что созданный VPS, где первые минуты
# работает unattended-upgrades. Без ожидания apt возвращает ошибку, пакет молча
# не ставится — так на чистой Ubuntu 24.04 не установился acl.
wait_for_apt() {
    local waited=0 limit="${1:-300}"
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
                /var/lib/apt/lists/lock &>/dev/null; do
        [ "$waited" -eq 0 ] && log "жду освобождения apt (идут автообновления)..."
        sleep 3
        waited=$((waited + 3))
        # Возвращаем 0, а не 1. Прежнее "return 1" убивало установщик молча:
        # оба вызова — голые команды под set -euo pipefail, поэтому сразу после
        # слова «продолжаю» скрипт завершался, не дойдя ни до одного die. Текст
        # прямо противоречил поведению, а на вызове перед выдачей доступа к
        # сертификату это ещё и происходило до сохранения секрета в telemt.conf.
        # Дубль этой функции в stacks/bots.sh с самого начала делал break, то
        # есть действительно продолжал, — приводим копии к одному поведению.
        [ "$waited" -ge "$limit" ] && { warn "apt занят дольше ${limit} с, продолжаю без ожидания."; return 0; }
    done
    return 0
}

[[ "$(id -u)" -eq 0 ]] || die "Запускай под root."

# Генератор self-SNI vhost общий с menus/telemt.sh: раньше он был двумя копиями
# одного heredoc, и одинаковый дефект пришлось бы чинить дважды.
#
# Пути считаем от своего расположения, а не жёстко. readlink -f обязателен:
# файл могут запустить по ссылке. Два dirname — потому что скрипт лежит в
# stacks/, а библиотеки в lib/: первый снимает имя файла, второй — каталог
# stacks. Свой lib/common.sh здесь не сорсится намеренно: установщик работает
# под set -euo pipefail со своими log/warn/die, а меню — без set -e, и общий
# файл пришлось бы писать под оба режима сразу.
VSM_ROOT="$(cd "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")" && pwd)"
VSM_LIB="$VSM_ROOT/lib"
[[ -f "$VSM_LIB/nginx_mask.sh" ]] || \
    die "Не найден $VSM_LIB/nginx_mask.sh — обнови VSM (install.sh) и повтори."
# shellcheck disable=SC1091
. "$VSM_LIB/nginx_mask.sh"

[[ -f "$VSM_LIB/nginx_panel_proxy.sh" ]] || \
    die "Не найден $VSM_LIB/nginx_panel_proxy.sh — обнови VSM (install.sh) и повтори."
# shellcheck disable=SC1091
. "$VSM_LIB/nginx_panel_proxy.sh"

# Страж «одна панель на сервер». Не обязателен: на установке, обновлённой не
# до конца, его может не быть, и разворачивать стек из-за этого мы не станем —
# отсутствие стража означает лишь, что вопрос про вторую панель не задан.
if [[ -f "$VSM_LIB/panels.sh" ]]; then
    # shellcheck disable=SC1091
    . "$VSM_LIB/panels.sh"
fi

: "${DOMAIN_PANEL:?Не задан DOMAIN_PANEL}"
: "${DOMAIN_REALITY:?Не задан DOMAIN_REALITY}"

[[ "$DOMAIN_PANEL" != "$DOMAIN_REALITY" ]] || \
    die "DOMAIN_PANEL и DOMAIN_REALITY должны быть РАЗНЫМИ поддоменами: nginx stream map строит ключи по SNI, одинаковые значения дают conflicting parameter."

TELEMT_PORT="${TELEMT_PORT:-8444}"
TELEMT_MASK_PORT="${TELEMT_MASK_PORT:-7444}"
PANEL_PORT="${PANEL_PORT:-9444}"
PANEL_ADMIN_USER="${PANEL_ADMIN_USER:-admin}"

mkdir -p "$STACK_CONF_DIR"
chmod 700 "$STACK_CONF_DIR"

# Секрет и пароль переиспользуются между запусками: перегенерация ломает
# все уже выданные клиентам ссылки.
if [[ -z "${TELEMT_SECRET:-}" ]]; then
    if [[ -f "$STACK_CONF" ]] && grep -q '^TELEMT_SECRET=' "$STACK_CONF"; then
        # shellcheck disable=SC1090
        TELEMT_SECRET="$(. "$STACK_CONF"; echo "${TELEMT_SECRET:-}")"
    fi
    TELEMT_SECRET="${TELEMT_SECRET:-$(openssl rand -hex 16)}"
fi
if [[ -z "${PANEL_ADMIN_PASS:-}" ]]; then
    if [[ -f "$STACK_CONF" ]] && grep -q '^PANEL_ADMIN_PASS=' "$STACK_CONF"; then
        # shellcheck disable=SC1090
        PANEL_ADMIN_PASS="$(. "$STACK_CONF"; echo "${PANEL_ADMIN_PASS:-}")"
    fi
    PANEL_ADMIN_PASS="${PANEL_ADMIN_PASS:-$(openssl rand -base64 20)}"
fi

# Префикс пути, по которому telemt_panel доступна на 443 домена панели.
# Переиспользуется между запусками по той же причине, что секрет и пароль:
# смена префикса ломает сохранённую владельцем ссылку.
if [[ -z "${PANEL_PREFIX:-}" ]]; then
    if [[ -f "$STACK_CONF" ]] && grep -q '^PANEL_PREFIX=' "$STACK_CONF"; then
        # shellcheck disable=SC1090
        PANEL_PREFIX="$(. "$STACK_CONF"; echo "${PANEL_PREFIX:-}")"
    fi
    PANEL_PREFIX="${PANEL_PREFIX:-$(panel_proxy_gen_prefix)}"
fi

# ---------------------------------------------------------------------------
# Утилита: запись ключа в конкретную секцию TOML.
# Наивная вставка "после строки tls_domain" кладёт ключ в ту секцию, где
# tls_domain фактически лежит — а это не обязательно [censorship].
# ---------------------------------------------------------------------------
toml_set_in_section() {
    local file="$1" section="$2" key="$3" value="$4"

    if ! grep -q "^\[${section}\]" "$file"; then
        printf '\n[%s]\n%s = %s\n' "$section" "$key" "$value" >> "$file"
        return
    fi

    if awk -v s="[$section]" -v k="$key" '
        $0==s {ins=1; next}
        /^\[/ {ins=0}
        ins && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {found=1}
        END {exit !found}
    ' "$file"; then
        awk -v s="[$section]" -v k="$key" -v v="$value" '
            $0==s {print; ins=1; next}
            /^\[/ {ins=0}
            ins && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print k" = "v; next}
            {print}
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        awk -v s="[$section]" -v k="$key" -v v="$value" '
            $0==s {print; print k" = "v; next}
            {print}
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# ---------------------------------------------------------------------------
# ЭТАП 0 — предварительные проверки
# ---------------------------------------------------------------------------
log "Этап 0: предварительные проверки (режим: $MODE)"

if ! command -v dig >/dev/null 2>&1; then
    log "  ставлю dnsutils (нужен dig для проверки DNS)..."
    wait_for_apt
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils >/dev/null 2>&1 || \
        die "Не удалось установить dig (пакет dnsutils/bind9-dnsutils)."
fi
command -v openssl >/dev/null 2>&1 || die "Нужен openssl."

for d in "$DOMAIN_PANEL" "$DOMAIN_REALITY"; do
    ip="$(dig +short "$d" | tail -1)"
    [[ -n "$ip" ]] || die "Домен $d не резолвится. Настрой DNS (A-запись на IP этого сервера) и повтори."
    log "  $d -> $ip"
done

busy="$(ss -tulnp 2>/dev/null | grep -E ":(${TELEMT_PORT}|${PANEL_PORT}|${TELEMT_MASK_PORT}) " || true)"
if [[ -n "$busy" ]]; then
    warn "Порты стека уже кем-то заняты:"
    echo "$busy"
    warn "Продолжаю, но при конфликте сверь вручную."
fi

if [[ "$MODE" == "addon" ]]; then
    [[ -d /etc/x-ui ]] || die "3x-ui-pro не установлена (/etc/x-ui не найден). Поставь панель через пункт меню 'Управление X-UI', затем повтори."
    systemctl is-active --quiet nginx || die "nginx не запущен — self-SNI маскировке нужен рабочий backend."
fi

apt-get update -qq

# ---------------------------------------------------------------------------
# ЭТАП 1 — 3x-ui-pro (только в режиме full)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "full" ]]; then
    log "Этап 1: установка 3x-ui-pro"
    cd /root
    XUI_URL="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh"
    wget -qO x-ui-latest.sh "$XUI_URL"
    [[ -s x-ui-latest.sh ]] || die "Установщик 3x-ui-pro скачался пустым."
    chmod +x x-ui-latest.sh

    fingerprint_upstream "$XUI_URL" x-ui-latest.sh

    # Снятие проверки CPU. Раньше её снимал только пункт меню «Установить
    # панель», а этот путь запускал тот же файл сырым — и установка всего стека
    # на хостере с эмулированным QEMU-процессором обрывалась здесь, на этапе 1,
    # чужой английской ошибкой. Проверяем фактом: молчаливый пропуск правки
    # означал бы падение через несколько минут работы.
    sed -i 's/^[[:space:]]*check_cpu[[:space:]]*$/: # проверка CPU снята VSM/' x-ui-latest.sh
    XUI_LEFT="$(grep -cE '^[[:space:]]*check_cpu([[:space:]]|$)' x-ui-latest.sh)" || XUI_LEFT=0
    if [[ "${XUI_LEFT:-0}" -ne 0 ]]; then
        warn "Проверка CPU снята не полностью (осталось ${XUI_LEFT}) — на QEMU-хостере установка оборвётся."
    fi

    # -auto_domain больше не передаём: автор снял его разбор в 18a2e01, а домены
    # мы и так задаём явно двумя строками ниже.
    # Массив, а не строка: пустая переменная в строке дала бы установщику
    # аргумент "" вместо ничего. Тот же класс ошибки, что уже ловили на
    # доменах сертификата.
    XUI_VER_ARG=()
    if [[ -n "${XUI_VERSION:-}" ]]; then
        XUI_VER_ARG=(-version "$XUI_VERSION")
        log "  версия 3x-ui задана явно: ${XUI_VERSION}"
    fi
    bash x-ui-latest.sh \
        -install y \
        "${XUI_VER_ARG[@]}" \
        -subdomain "$DOMAIN_PANEL" \
        -reality_domain "$DOMAIN_REALITY"
else
    log "Этап 1: пропущен (режим addon, панель уже установлена)"
fi

verify_or_die nginx -t
verify_or_die systemctl is-active --quiet nginx
verify_or_die systemctl is-active --quiet x-ui

PANEL_WEBPATH="$(/usr/local/x-ui/x-ui setting -show true 2>&1 | grep -oP 'webBasePath:\s*\K\S+' || true)"

# Приводим к виду /путь/ ПРЯМО ЗДЕСЬ, а не в местах вывода. Панель отдаёт путь
# и без крайних слэшей, а ниже к нему дописывается panel/: из "/abc" вышло бы
# склеенное "/abcpanel/" — адрес выглядит достоверно и ведёт в 404. Ту же
# нормализацию делает xui_panel_url в lib/common.sh.
#
# Полная форма if/fi, а не "[[ ... ]] && присваивание": под set -e ложное
# условие в таком виде возвращает 1 и роняет установщик молча — ровно тот
# класс дефекта, что уже дважды ловили в этом файле.
if [[ -n "$PANEL_WEBPATH" ]]; then
    if [[ "${PANEL_WEBPATH#/}" == "$PANEL_WEBPATH" ]]; then
        PANEL_WEBPATH="/$PANEL_WEBPATH"
    fi
    if [[ "${PANEL_WEBPATH%/}" == "$PANEL_WEBPATH" ]]; then
        PANEL_WEBPATH="$PANEL_WEBPATH/"
    fi
fi

# ---------------------------------------------------------------------------
# ЭТАП 2 — self-SNI vhost для telemt (БЕЗ proxy_protocol)
# ---------------------------------------------------------------------------
log "Этап 2: nginx vhost для self-SNI маскировки (127.0.0.1:${TELEMT_MASK_PORT})"

# nginx.conf обязан подключать conf.d — иначе наш файл не прочитается.
if ! grep -qE '^\s*include\s+/etc/nginx/conf\.d/\*\.conf;' /etc/nginx/nginx.conf; then
    warn "nginx.conf не подключает conf.d — добавляю include."
    sed -i '0,/^http\s*{/s//http {\n    include \/etc\/nginx\/conf.d\/*.conf;/' /etc/nginx/nginx.conf
fi

# Сборка, проверка и откат при неудаче — в lib/nginx_mask.sh. Откат тут не
# роскошь: битый файл в conf.d не даёт nginx стартовать вообще, и упасть,
# оставив его на диске, значит уронить панель при ближайшем рестарте.
nginx_mask_apply "$DOMAIN_PANEL" "$TELEMT_MASK_PORT" || \
    die "Не удалось установить vhost self-SNI маскировки (см. сообщение выше)."

# Та же гонка, что у telemt и панели ниже: systemctl reload возвращается по
# факту доставки сигнала, а слушателя на маскировочном порту nginx поднимает
# чуть позже. Проверка без ожидания успевала раньше и получала «соединение
# отклонено» — на установке с нуля это обрывало весь стек на этапе 2.
#
# Второе: curl тут в подстановке команды, а в файле set -e. Ненулевой код
# curl ронял скрипт РАНЬШЕ строки с die, поэтому обрыв выглядел как молчание —
# ни причины, ни этапа. Отсюда "|| true", как уже сделано для панели.
mask_responds() {
    local code
    code="$(curl -sk --max-time 5 --resolve "${DOMAIN_PANEL}:${TELEMT_MASK_PORT}:127.0.0.1" \
        "https://${DOMAIN_PANEL}:${TELEMT_MASK_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null)" || return 1
    [[ "$code" == "200" ]]
}
if ! wait_until 30 mask_responds; then
    MASK_CODE="$(curl -sk --max-time 5 --resolve "${DOMAIN_PANEL}:${TELEMT_MASK_PORT}:127.0.0.1" \
        "https://${DOMAIN_PANEL}:${TELEMT_MASK_PORT}/" -o /dev/null -w '%{http_code}' 2>/dev/null)" || MASK_CODE=000
    die "self-SNI vhost вернул $MASK_CODE вместо 200 (ждали 30 с)."
fi
log "self-SNI vhost отвечает 200."

# ---------------------------------------------------------------------------
# ЭТАП 3 — telemt
# ---------------------------------------------------------------------------
log "Этап 3: установка telemt (порт ${TELEMT_PORT})"

# Скачиваем отдельным шагом, а не конвейером в sh.
#
# Установщик telemt берётся с ветки main и выполняется от root — то же, за что
# 3x-ui-pro получил отпечаток на этапе 1, и то же, чего этот путь до сих пор не
# делал. Причём путей запуска этого файла на сервере не один: MTProxyL дёргает
# ТОТ ЖЕ адрес из своего lib/detect.sh, и её панель тоже. Чужие пути VSM не
# контролирует — за результатом там следит реестр решений (позиция telemt_mask
# в lib/expectations.sh), — но свой обязан закрыть.
#
# Отдельный файл нужен и технически: посчитать sha256 у потока, уходящего в sh,
# нельзя.
TELEMT_URL="https://raw.githubusercontent.com/telemt/telemt/main/install.sh"
TELEMT_INSTALLER=/root/telemt-install.sh
curl -fsSL --max-time 60 "$TELEMT_URL" -o "$TELEMT_INSTALLER" \
    || die "Не удалось скачать установщик telemt."
[[ -s "$TELEMT_INSTALLER" ]] || die "Установщик telemt скачался пустым."
fingerprint_upstream "$TELEMT_URL" "$TELEMT_INSTALLER"

# ПРО СЕКРЕТ В СПИСКЕ ПРОЦЕССОВ. -s кладёт секрет прокси в argv, а argv виден
# любому пользователю системы через ps на всё время установки. Убрать это
# нельзя: установщик читает секрет ТОЛЬКО аргументом, окружение он не смотрит
# (проверено чтением его разбора). Сгенерировать секрет ему самому мы тоже не
# можем — при переустановке он обязан совпасть с прежним, иначе у всех клиентов
# разом перестанет работать подключение. Размен принят осознанно.
sh "$TELEMT_INSTALLER" -d "$DOMAIN_PANEL" -p "$TELEMT_PORT" -s "$TELEMT_SECRET" -l en
rm -f "$TELEMT_INSTALLER"

mkdir -p /etc/systemd/system/telemt.service.d
cat > /etc/systemd/system/telemt.service.d/nginx-dependency.conf << 'EOF'
[Unit]
After=network-online.target nginx.service
Requires=nginx.service
EOF

TOML=/etc/telemt/telemt.toml
[[ -f "$TOML" ]] || die "telemt не создал $TOML."
toml_set_in_section "$TOML" censorship mask true
toml_set_in_section "$TOML" censorship mask_host '"127.0.0.1"'
toml_set_in_section "$TOML" censorship mask_port "$TELEMT_MASK_PORT"

systemctl daemon-reload
systemctl restart telemt
verify_or_die systemctl is-active --quiet telemt

command -v ufw >/dev/null 2>&1 && ufw allow "${TELEMT_PORT}/tcp" >/dev/null 2>&1 || true

# Ждём готовности, а не спим фиксированно: systemd считает юнит активным сразу,
# а telemt после этого ещё поднимает пул middle-proxy — на живом сервере это
# заняло дольше двух секунд, и установка падала на Этапе 3 при полностью
# исправном сервисе, так и не добравшись до telemt_panel.
log "жду готовности telemt..."
if ! wait_until 30 curl -sf "http://127.0.0.1:9091/v1/users" -o /dev/null; then
    die "API telemt (127.0.0.1:9091) не отвечает 30 секунд. Смотри: journalctl -u telemt -n 50"
fi

# Присваивание с "|| echo 000" внутри подстановки склеивало вывод curl с эхом и
# давало "000000" вместо кода ответа. Код перезаписываем целиком.
E2E="$(curl -sk --max-time 10 "https://127.0.0.1:${TELEMT_PORT}/" -o /dev/null -w '%{http_code}')" || E2E=000
if [[ "$E2E" == "200" ]]; then
    log "Сквозной self-SNI тест через telemt: 200."
else
    warn "Сквозной self-SNI тест вернул $E2E вместо 200 — маскировка может не работать."
    warn "Проверь вручную: curl -skv https://127.0.0.1:${TELEMT_PORT}/ и journalctl -u telemt -n 50"
fi

log "telemt установлен и проверен."

# ---------------------------------------------------------------------------
# ЭТАП 4 — telemt_panel
# ---------------------------------------------------------------------------
log "Этап 4: установка telemt_panel (порт ${PANEL_PORT})"

# Установщик интерактивен, и ответы ему нельзя подать ни через "curl | bash"
# (там stdin занят текстом самого скрипта), ни просто через stdin: свои вопросы
# он читает из /dev/tty напрямую — "read -r _val < /dev/tty". Пайп на stdin он
# попросту игнорирует, а без управляющего терминала (запуск из systemd, по cron
# или отсоединённым сеансом) падает с "/dev/tty: No such device or address" и
# "_val: unbound variable". Поэтому скачиваем установщик в файл и запускаем под
# псевдотерминалом script(1): /dev/tty у него появляется, а ответы приходят
# туда же со стандартного ввода.
# Страж одной панели. Спрашиваем ДО скачивания установщика: развёртывание
# стека доходит сюда после установки 3x-ui-pro, telemt и настройки nginx, и
# упереться в вопрос на четвёртом этапе неприятно — но гораздо хуже молча
# поставить вторую админку рядом с уже работающей.
#
# Отказ здесь НЕ роняет стек: telemt и маскировка уже подняты и работают,
# без панели они полностью функциональны. Поэтому предупреждаем и идём дальше,
# а не die.
if declare -F panel_ensure_exclusive >/dev/null 2>&1; then
    if ! panel_ensure_exclusive telemt; then
        warn "telemt_panel не устанавливается — оставлена прежняя панель."
        warn "Сам telemt и маскировка работают: панель им не нужна."
        SKIP_PANEL=1
    fi
fi

if [[ "${SKIP_PANEL:-0}" -eq 0 ]]; then
command -v script >/dev/null 2>&1 || \
    die "Нужен script(1) из util-linux — через него установщику telemt_panel выдаётся псевдотерминал."
PANEL_INSTALLER="$(mktemp /tmp/telemt-panel-install.XXXXXX.sh)"
trap 'rm -f "$PANEL_INSTALLER"' EXIT
curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh -o "$PANEL_INSTALLER"
[[ -s "$PANEL_INSTALLER" ]] || die "Не удалось скачать установщик telemt_panel."

# Порядок вопросов: API URL, auth header, admin user, admin password,
# путь к бинарнику telemt, имя systemd-юнита. Пустая строка = дефолт.
#
# "stty -echo" плюс пауза перед подачей ответов — против утечки пароля. Строчная
# дисциплина псевдотерминала отражает всё поданное на вход СРАЗУ по приходу,
# задолго до того, как установщик доберётся до своего prompt_secret и сам
# погасит эхо; без этого пароль админа уходит в stdout открытым текстом и
# оседает в любом логе, куда перенаправлен вывод. Пауза нужна, чтобы stty успел
# отработать раньше, чем script нальёт ответы в терминал. Если паузы всё же не
# хватит, установка не сломается — вернётся прежнее поведение с эхом.
{ sleep 2; printf '\n\n%s\n%s\n\n\n' "$PANEL_ADMIN_USER" "$PANEL_ADMIN_PASS"; } \
    | script -qe -c "stty -echo 2>/dev/null; bash '$PANEL_INSTALLER'" /dev/null

PANEL_TOML=/etc/telemt-panel/config.toml
[[ -f "$PANEL_TOML" ]] || die "telemt_panel не создал $PANEL_TOML."

# Панель слушает ТОЛЬКО loopback и без своего TLS.
#
# Раньше было 0.0.0.0 плюс собственный сертификат домена REALITY, и снаружи это
# выглядело как админ-форма с валидным сертификатом на нестандартном порту —
# самый громкий объект на сервере. Сканеру хватало одного соединения, чтобы
# классифицировать IP, и работа по маскировке порта telemt после этого теряла
# смысл. Теперь TLS терминирует nginx на 443 домена панели, а попасть внутрь
# можно по случайному префиксу пути (см. ниже).
# Перевод панели на loopback, снятие её TLS, отзыв доступа к приватному ключу и
# закрытие порта — всё в panel_proxy_localize, общей с меню. Держать здесь
# отдельную копию нельзя: ровно так разошлись две копии wait_for_apt, и
# разошлись в опасную сторону.
panel_proxy_localize "$PANEL_TOML" "$PANEL_PORT" "$DOMAIN_REALITY" || \
    die "не удалось перевести telemt_panel на loopback (причина выше)."
verify_or_die systemctl is-active --quiet telemt-panel

# Та же гонка, что и у telemt: ждём готовности, а не спим наугад. Обращаемся по
# http — TLS у панели больше нет.
if ! wait_until 20 curl -s --max-time 5 "http://127.0.0.1:${PANEL_PORT}/" -o /dev/null; then
    warn "telemt_panel не отвечает на http://127.0.0.1:${PANEL_PORT}/ — смотри journalctl -u telemt-panel"
fi
PCODE="$(curl -s --max-time 10 "http://127.0.0.1:${PANEL_PORT}/" -o /dev/null -w '%{http_code}')" || PCODE=000
[[ "$PCODE" == "200" ]] || warn "telemt_panel вернул $PCODE вместо 200 — смотри journalctl -u telemt-panel"

# Подключаем панель к 443 домена панели по случайному префиксу пути.
#
# Блок вписывается в vhost панели, а тот лежит в sites-enabled — каталоге,
# который установщик и патч 3x-ui-pro вычищают целиком. Пережить это он, в
# отличие от маски, не может: nginx не умеет добавлять location в чужой
# server{} из отдельного файла. Поэтому блок помечен маркерами и
# переприменяется пунктом меню «Восстановить конфигурацию nginx» — тем же, что
# чинит маску после патча панели.
log "Этап 5: доступ к telemt_panel через 443 домена панели"
PANEL_VHOST="$(nginx_mask_panel_vhost "$DOMAIN_PANEL")" || \
    die "не найден vhost домена $DOMAIN_PANEL — панель некуда подключить."
panel_proxy_apply "$PANEL_VHOST" "$PANEL_PREFIX" "$PANEL_PORT" || \
    die "не удалось подключить telemt_panel к nginx (причина выше)."

if PANEL_URL_CHECK="$(panel_proxy_verify "$DOMAIN_PANEL" "$PANEL_PREFIX")"; then
    log "  панель отвечает по своему адресу ($PANEL_URL_CHECK)"
else
    warn "панель по адресу через nginx вернула $PANEL_URL_CHECK — проверь вручную."
    warn "если вёрстка поедет, панель не умеет работать из подкаталога: тогда"
    warn "оставь её на loopback и ходи через ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT}"
fi

fi   # конец блока SKIP_PANEL: этапы 4 и 5 пропускаются целиком, если владелец
     # отказался удалять уже стоящую панель. Пропускается и подключение к
     # nginx: блок, ведущий на непоставленную панель, отдавал бы ошибку шлюза
     # по секретному адресу — то есть подтверждал бы, что там что-то есть.

# ---------------------------------------------------------------------------
# СОХРАНЕНИЕ СОСТОЯНИЯ
# ---------------------------------------------------------------------------
# printf %q — значения переживают повторный source без риска инъекции.
{
    echo "# Создано stacks/telemt.sh, не редактируй вручную."
    printf 'DOMAIN_PANEL=%q\n'     "$DOMAIN_PANEL"
    printf 'DOMAIN_REALITY=%q\n'   "$DOMAIN_REALITY"
    printf 'TELEMT_PORT=%q\n'      "$TELEMT_PORT"
    printf 'TELEMT_MASK_PORT=%q\n' "$TELEMT_MASK_PORT"
    # Порт и префикс панели — только если она действительно поставлена.
    #
    # Иначе шапка меню показывала бы адрес, которого нет: telemt_panel_url в
    # lib/config.sh собирает ссылку именно из этих двух значений и о том, что
    # панели нет, не знает. Строка выглядела бы достоверной и вела в никуда.
    if [[ "${SKIP_PANEL:-0}" -eq 0 ]]; then
        printf 'PANEL_PORT=%q\n'   "$PANEL_PORT"
        printf 'PANEL_PREFIX=%q\n' "$PANEL_PREFIX"
    fi
    printf 'TELEMT_SECRET=%q\n'    "$TELEMT_SECRET"
    printf 'PANEL_ADMIN_USER=%q\n' "$PANEL_ADMIN_USER"
    printf 'PANEL_ADMIN_PASS=%q\n' "$PANEL_ADMIN_PASS"
} > "$STACK_CONF"
chmod 600 "$STACK_CONF"

{
    echo "Стек telemt — учётные данные (создано $(date '+%Y-%m-%d %H:%M:%S'))"
    # Адрес в длинной форме, с panel/ на конце: это и есть форма входа, и ровно
    # так его собирает xui_panel_url для шапок меню. Короткая форма работала,
    # но расходилась с шапками, и было не понять, какая из двух правильная.
    echo "Панель 3x-ui-pro:   https://${DOMAIN_PANEL}${PANEL_WEBPATH:-/}panel/"
    echo "telemt порт:        ${TELEMT_PORT}"
    echo "telemt secret:      ${TELEMT_SECRET}"
    echo "telemt_panel:       https://${DOMAIN_PANEL}/${PANEL_PREFIX}/"
    echo "telemt_panel логин: ${PANEL_ADMIN_USER}"
    echo "telemt_panel пароль: ${PANEL_ADMIN_PASS}"
} > "$STACK_CREDS"
chmod 600 "$STACK_CREDS"

cat << SUMMARY

════════════════════════════════════════════════════════════════
УСТАНОВКА ЗАВЕРШЕНА (режим: ${MODE})

  Панель 3x-ui-pro:    https://${DOMAIN_PANEL}${PANEL_WEBPATH:-/<путь из вывода установщика>/}panel/
  REALITY SNI-ключ:    ${DOMAIN_REALITY}
  telemt порт:         ${TELEMT_PORT}  (self-SNI цель: ${DOMAIN_PANEL})
  telemt_panel:        https://${DOMAIN_PANEL}/${PANEL_PREFIX}/
                       (порт ${PANEL_PORT} только на 127.0.0.1, наружу не открыт)
  Логин панели telemt: ${PANEL_ADMIN_USER}

  Секрет и пароль НЕ печатаются здесь намеренно — они сохранены в
  ${STACK_CREDS} (права 600).
  Посмотреть: пункт меню "Показать учётные данные".

ДАЛЬШЕ:
  • SYN FIX (MEKO) — отдельный пункт меню.
  • Постквантовый TLS — пункт "Пересборка nginx с OpenSSL 3.5".
  • После любого патча/переустановки 3x-ui-pro прогони пункт
    "Статус и диагностика" — он проверит, жива ли маскировка.
════════════════════════════════════════════════════════════════
SUMMARY
