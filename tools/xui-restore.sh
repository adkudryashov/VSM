#!/bin/bash
# ======================================================================
# ВЕРНУТЬ 3x-ui ИЗ СУТОЧНОЙ КОПИИ VSM
#
#   bash tools/xui-restore.sh <архив config-*.tar.gz> [--yes] [--dry-run]
#
# ЗАЧЕМ. Сервер переустановили с нуля на тех же доменах. Свежая 3x-ui — это
# пустая панель со случайными путями: клиентов нет, их ссылки не работают.
# Этот скрипт возвращает на установленную панель снимок из суточной копии
# (tools/vsm-backup.sh, ветка xui/): базу с клиентами и ключами и всё, куда
# установщик вписал её порты и пути — nginx, шаблон Clash-подписки, страницу
# диагностики, сайт-заглушку, юнит mtr-backend. После этого ссылки клиентов
# снова ведут туда же, куда вели.
#
# ЧТО НУЖНО ЗАРАНЕЕ. Панель должна быть установлена — стеком или пунктом
# «Установить» меню X-UI — на ТЕХ ЖЕ доменах, что в копии. Бинарники, пакеты
# и сертификаты ставит установщик; снимок их не везёт (почему — в шапке
# xui_snapshot в tools/vsm-backup.sh). Домены сверяются, и на чужих скрипт
# отказывает: nginx из копии указывал бы на сертификаты, которых здесь нет.
#
# КАК. Перед заменой текущее состояние уходит в /var/backups/vsm/xui/. База
# кладётся механизмом резервного копирования SQLite (она в режиме WAL, и
# хвосты журнала свежей панели удаляются — иначе SQLite наложил бы их поверх).
# nginx проверяется `nginx -t` до перезапуска. После — проверка фактом: панель
# и xray живы, входящих столько же, сколько в копии, путь панели отвечает 200,
# и подписка настоящего клиента из копии отдаёт ссылки. Не прошло — всё
# возвращается как было до запуска.
# ======================================================================
set -uo pipefail

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
WWW_DIR="${WWW_DIR:-/var/www}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
SAVE_DIR="${XUI_RESTORE_SAVE_DIR:-/var/backups/vsm/xui}"
WAIT="${XUI_RESTORE_WAIT:-30}"
SETTLE="${XUI_RESTORE_SETTLE:-8}"

RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; NC=$'\e[0m'
say()  { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "$YELLOW" "$*" "$NC" >&2; }
die()  { printf '%s❌ %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }

ARCHIVE="" YES=0 DRY=0
for arg in "$@"; do
    case "$arg" in
        --yes) YES=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '3,30p' "$(readlink -f "${BASH_SOURCE[0]}")"; exit 0 ;;
        -*) die "Неизвестный ключ: $arg" ;;
        *) ARCHIVE="$arg" ;;
    esac
done
[ -n "$ARCHIVE" ] || die "Укажите архив: bash tools/xui-restore.sh <config-*.tar.gz>"
[ -f "$ARCHIVE" ] || die "Нет файла: $ARCHIVE"
[ "$(id -u)" -eq 0 ] || [ -n "${XUI_RESTORE_TEST:-}" ] || die "Нужен root."
# Список — в переменную, а не в конвейер с grep -q. При pipefail grep -q
# выходит на первом совпадении, tar получает SIGPIPE, и весь конвейер
# считается неудачным: на настоящем архиве стенда (64 файла) скрипт отвечал
# «снимка нет» при снимке на месте. В тестах архив был крошечный, и tar
# успевал закончить раньше — поймано только живым прогоном 24.09.2026.
LISTING="$(tar -tzf "$ARCHIVE" 2>/dev/null)" || die "Архив не читается: $ARCHIVE"
grep -qx 'xui/x-ui.db' <<< "$LISTING" \
    || die "В архиве нет снимка 3x-ui (xui/x-ui.db). Он появился в копиях с 24.09.2026."
[ -f "$XUI_DB" ] || die "3x-ui не установлена ($XUI_DB нет). Сначала поставьте панель на тех же доменах."

# --- чтение баз ----------------------------------------------------------
# Одна маленькая программа на Python на всё чтение: sqlite3 из командной
# строки есть не везде, а python3 нужен VSM и так.
dbinfo() { # база поле: domain | inbounds | web | sub | subid | remarks | clients
    python3 - "$1" "$2" <<'PY'
import json, re, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
what = sys.argv[2]
def setting(k):
    r = c.execute("select value from settings where key = ?", (k,)).fetchone()
    return r[0] if r else ""
if what == "domain":
    m = re.match(r"https?://([^/:?]+)", setting("subURI"))
    print(m.group(1) if m else "")
elif what == "inbounds":
    print(c.execute("select count(*) from inbounds").fetchone()[0])
elif what == "web":
    print(setting("webBasePath"))
elif what == "sub":
    print(setting("subPath"))
elif what == "subid":
    try:
        r = c.execute("select sub_id from clients where sub_id <> '' and enable limit 1").fetchone()
    except sqlite3.OperationalError:
        r = None
    print(r[0] if r else "")
elif what == "clients":
    try:
        print(c.execute("select count(*) from clients").fetchone()[0])
    except sqlite3.OperationalError:
        print("?")
elif what == "remarks":
    print(", ".join(r[0] for r in c.execute("select remark from inbounds order by id")))
PY
}

db_put() { # откуда куда — копия базы механизмом SQLite, хвосты журнала долой
    rm -f "$2-wal" "$2-shm"
    python3 - "$1" "$2" <<'PY'
import os, sqlite3, sys
s = sqlite3.connect(sys.argv[1]); d = sqlite3.connect(sys.argv[2])
s.backup(d); d.close(); s.close()
os.chmod(sys.argv[2], 0o600)
PY
}

# --- распаковка и сверка -------------------------------------------------
mkdir -p "$SAVE_DIR" && chmod 700 "$SAVE_DIR" || die "Не создать $SAVE_DIR"
STAGE="$(mktemp -d "$SAVE_DIR/.stage.XXXXXX")" || die "Не создать временный каталог"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
tar -xzf "$ARCHIVE" -C "$STAGE" xui/ 2>/dev/null
[ -f "$STAGE/xui/x-ui.db" ] || die "Снимок 3x-ui не распаковался."
SNAP="$STAGE/xui"

want_domain="$(dbinfo "$SNAP/x-ui.db" domain)"
here_domain="$(dbinfo "$XUI_DB" domain)"
want_n="$(dbinfo "$SNAP/x-ui.db" inbounds)"

say "Снимок 3x-ui из $(basename "$ARCHIVE"):"
say "  домен панели: ${want_domain:-?}; входящих: $want_n; клиентов: $(dbinfo "$SNAP/x-ui.db" clients)"
say "  входящие: $(dbinfo "$SNAP/x-ui.db" remarks)"
say "Сейчас на сервере: домен ${here_domain:-?}; входящих: $(dbinfo "$XUI_DB" inbounds)"

if [ -z "$want_domain" ] || [ "$want_domain" != "$here_domain" ]; then
    die "Домены не совпадают (${want_domain:-?} в копии, ${here_domain:-?} здесь). Копию возвращают на панель с теми же доменами; для другого сервера — шаблон настроек."
fi
[ -d "$SNAP/nginx" ] || die "В снимке нет конфигов nginx — без них пути разойдутся с базой."

if [ "$DRY" -eq 1 ]; then
    say "Пробный прогон: ничего не менялось."
    exit 0
fi
if [ "$YES" -ne 1 ]; then
    warn "Текущая база панели и весь nginx будут заменены снимком."
    warn "Всё, что заведено в панели после снятия копии, пропадёт."
    answer=""
    read -r -p "Введите ВЕРНУТЬ для продолжения: " answer
    [ "$answer" = "ВЕРНУТЬ" ] || { say "Отменено."; exit 0; }
fi

# --- сохранить текущее ---------------------------------------------------
SAVED="$SAVE_DIR/before-restore-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SAVED/www" || die "Не создать $SAVED"
db_put "$XUI_DB" "$SAVED/x-ui.db" || die "Не сохранить текущую базу"
cp -a "$NGINX_DIR" "$SAVED/nginx" || die "Не сохранить текущий nginx"
for d in subpage diagnostics html; do
    [ -e "$WWW_DIR/$d" ] && [ -e "$SNAP/www/$d" ] && cp -a "$WWW_DIR/$d" "$SAVED/www/$d"
done
[ -f "$UNIT_DIR/mtr-backend.service" ] && cp -a "$UNIT_DIR/mtr-backend.service" "$SAVED/"
say "Текущее состояние сохранено: $SAVED"

put_state() { # откуда: каталог со снимком (x-ui.db, nginx/, www/, mtr-backend.service)
    local src="$1" d
    systemctl stop x-ui mtr-backend 2>/dev/null
    db_put "$src/x-ui.db" "$XUI_DB" || return 1
    # nginx заменяется целиком, а не поверх: файл, которого не было в копии,
    # остался бы вторым конфигом — ровно так однажды уже падал nginx на дубле
    # limit_req_zone.
    rm -rf "$NGINX_DIR.vsm-new"
    cp -a "$src/nginx" "$NGINX_DIR.vsm-new" || return 1
    rm -rf "${NGINX_DIR:?}" && mv "$NGINX_DIR.vsm-new" "$NGINX_DIR" || return 1
    for d in subpage diagnostics html; do
        [ -e "$src/www/$d" ] || continue
        mkdir -p "$WWW_DIR/$d"
        cp -a "$src/www/$d/." "$WWW_DIR/$d/"
        chown -R www-data:www-data "$WWW_DIR/$d" 2>/dev/null
    done
    if [ -f "$src/mtr-backend.service" ]; then
        cp -a "$src/mtr-backend.service" "$UNIT_DIR/mtr-backend.service"
        systemctl daemon-reload 2>/dev/null
    fi
    return 0
}

start_all() {
    systemctl start x-ui 2>/dev/null
    systemctl restart mtr-backend 2>/dev/null
    nginx -t >/dev/null 2>&1 && systemctl restart nginx 2>/dev/null
}

rollback() {
    warn "$1 — возвращаю как было."
    put_state "$SAVED"
    start_all
    die "Копия не возвращена. Прежнее состояние восстановлено из $SAVED"
}

# --- замена --------------------------------------------------------------
put_state "$SNAP" || rollback "замена не удалась"
if ! nginx -t >/dev/null 2>&1; then
    nginx -t 2>&1 | tail -3 >&2
    rollback "nginx не принял конфиг из копии"
fi
start_all

# --- проверка фактом -----------------------------------------------------
alive() {
    systemctl is-active --quiet x-ui && pgrep -f xray-linux >/dev/null 2>&1
}
i=0
until alive; do
    i=$((i + 1))
    [ "$i" -ge "$WAIT" ] && rollback "панель или xray не поднялись за $WAIT с"
    sleep 1
done
# Второй взгляд: xray с негодным конфигом стартует и падает не сразу.
sleep "$SETTLE"
alive || rollback "xray упал вскоре после запуска"
systemctl is-active --quiet nginx || rollback "nginx не работает"
got_n="$(dbinfo "$XUI_DB" inbounds)"
[ "$got_n" = "$want_n" ] || rollback "входящих $got_n, в копии $want_n"

http_code() {
    curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        --resolve "$want_domain:443:127.0.0.1" "https://$want_domain$1" 2>/dev/null
}
web="$(dbinfo "$XUI_DB" web)"
code="$(http_code "$web")"
[ "$code" = "200" ] || rollback "путь панели отвечает $code, а не 200"
subid="$(dbinfo "$XUI_DB" subid)"
if [ -n "$subid" ]; then
    code="$(http_code "$(dbinfo "$XUI_DB" sub)$subid")"
    [ "$code" = "200" ] || rollback "подписка клиента из копии отвечает $code, а не 200"
    say "  подписка клиента из копии отдаёт ссылки (200)"
else
    warn "  клиентов с подпиской в копии нет — ссылки проверить нечем"
fi

# UDP-входящие: панель фаервол не трогает, а на свежей системе он пуст.
if command -v ufw >/dev/null 2>&1; then
    python3 - "$XUI_DB" <<'PY' | while read -r port; do ufw allow "$port/udp" >/dev/null 2>&1 && say "  фаервол: открыт $port/udp"; done
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for (port,) in c.execute("select port from inbounds where enable and port > 0 and "
                         "protocol in ('amneziawg','hysteria','wireguard')"):
    print(port)
PY
fi

say "${GREEN}✓ 3x-ui возвращена из копии: входящих $got_n, панель и подписка отвечают.${NC}"
say "  Прежнее состояние (свежая установка): $SAVED"
say "  Если на сервере стоит стек telemt — пункт «Восстановить nginx» в его меню"
say "  сверит маскировку с тем, что пришло из копии."
