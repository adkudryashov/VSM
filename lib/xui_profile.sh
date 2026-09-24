# shellcheck shell=bash
# Шаблон настроек 3x-ui: общие вопросы для меню X-UI и установщика стека.
#
# Сама работа — в tools/xui-profile.py: там разбор базы, подстановки, копия
# и откат. Здесь только то, что спрашивают у человека, — один раз и одинаково
# в обоих местах, откуда ставится 3x-ui. Иначе вопрос разъехался бы: в одном
# месте про имя сервера спросили бы, в другом забыли бы.

XUI_PROFILE_FILE="${XUI_PROFILE_FILE:-/etc/vsm/xui-profile.json}"
XUI_PROFILE_TOOL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/tools/xui-profile.py"

# Имя сервера, с которого снят шаблон: подсказка по умолчанию. На новом
# сервере его обычно меняют — «My1Cent» у другого хостера станет другим.
xui_profile_source_name() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"].get("NAME", ""))' \
        "$XUI_PROFILE_FILE" 2>/dev/null
}

# Шаблон, принесённый с другого сервера, забирается из /root.
#
# На новом сервере /etc/vsm ещё нет: install.sh его не создаёт, каталог
# появляется при установке стека. Команда переноса поэтому кладёт файл в
# /root, а VSM сам переносит его на место — одна команда scp вместо двух с
# mkdir посередине, в которых легко ошибиться.
xui_profile_pickup() {
    local dropped="/root/xui-profile.json"
    [ -f "$XUI_PROFILE_FILE" ] && return 0
    [ -f "$dropped" ] || return 0
    local dir; dir="$(dirname "$XUI_PROFILE_FILE")"
    # Права отдельной командой: у mkdir -p -m режим получает только последний
    # каталог, а создаётся он здесь обычно впервые.
    mkdir -p "$dir" && chmod 700 "$dir" \
        && install -m 600 "$dropped" "$XUI_PROFILE_FILE" \
        && rm -f "$dropped" \
        && echo -e "${C_DESC:-}   Шаблон забран из $dropped в $XUI_PROFILE_FILE${NC:-}"
}

# Спрашивает, накладывать ли шаблон, и с каким именем сервера.
# Итог — в XUI_PROFILE_APPLY (0 или 1) и XUI_PROFILE_NAME.
# Шаблона нет — молчит: вопрос без предмета был бы шумом.
xui_profile_ask() {
    XUI_PROFILE_APPLY=0
    XUI_PROFILE_NAME=""
    xui_profile_pickup
    [ -f "$XUI_PROFILE_FILE" ] || return 0
    echo -e "\n${CYAN}Шаблон настроек 3x-ui найден.${NC}"
    python3 "$XUI_PROFILE_TOOL" show --profile "$XUI_PROFILE_FILE" 2>&1 | sed 's/^/   /'
    echo -e "${C_DESC}   На свежую панель лягут ваши подписки, названия,"
    echo -e "   хосты и параметры входящих; hy2 и awg создадутся с новыми ключами."
    echo -e "   Порты, пути, ключи REALITY и секретный путь панели останутся от"
    echo -e "   установщика. Клиентов в шаблоне нет — их заводят потом.${NC}"
    local answer question="${1:-Наложить шаблон после установки 3x-ui?}"
    read -r -p "$question [Y/n]: " answer || return 0
    case "$answer" in [Nn]*) return 0 ;; esac
    local def name
    def="$(xui_profile_source_name)"
    echo -e "${C_DESC}   Имя сервера попадёт в названия входящих и подписки:"
    echo -e "   «флаг ИМЯ reality». Флаг страны определит установщик.${NC}"
    read -r -p "Имя сервера для подписок [${def:-без имени}] (- — без имени): " name || return 0
    name="${name:-$def}"
    [ "$name" = "-" ] && name=""
    XUI_PROFILE_APPLY=1
    XUI_PROFILE_NAME="$name"
}

# ----------------------------------------------------------------------
# Возврат 3x-ui из суточной копии VSM — на тот же сервер с теми же доменами.
#
# Шаблон — для НОВОГО сервера: переносит вкус, клиенты и ссылки там новые.
# Копия — для ПЕРЕУСТАНОВЛЕННОГО: возвращает клиентов, ключи и пути, и ссылки
# у пользователей продолжают работать. Предлагается раньше шаблона и
# исключает его: наложить шаблон поверх возвращённой панели значит испортить
# то, ради чего её возвращали.
XUI_RESTORE_TOOL="$(dirname "$XUI_PROFILE_TOOL")/xui-restore.sh"

# Копии со снимком 3x-ui для домена, новые первыми. Строка на копию:
# «путь|дата|входящих|клиентов». Смотрим и в /root: на переустановленный
# сервер архив приносят руками, туда же, куда и шаблон.
xui_restore_candidates() {
    local domain="$1"
    python3 - "$domain" /var/backups/vsm/config /root <<'PY' 2>/dev/null
import glob, os, re, sqlite3, sys, tarfile, tempfile, time
domain = sys.argv[1]
files = []
for d in sys.argv[2:]:
    files += glob.glob(os.path.join(d, "config-*.tar.gz"))
for path in sorted(set(files), key=os.path.getmtime, reverse=True):
    try:
        with tarfile.open(path) as t, tempfile.TemporaryDirectory() as tmp:
            m = t.getmember("xui/x-ui.db")
            t.extract(m, tmp)
            c = sqlite3.connect(os.path.join(tmp, "xui/x-ui.db"))
            uri = (c.execute("select value from settings where key='subURI'").fetchone() or [""])[0]
            host = (re.match(r"https?://([^/:?]+)", uri or "") or [None, ""])[1]
            if host != domain:
                continue
            n = c.execute("select count(*) from inbounds").fetchone()[0]
            try:
                k = c.execute("select count(*) from clients").fetchone()[0]
            except sqlite3.Error:
                k = "?"
            c.close()
    except (KeyError, tarfile.TarError, sqlite3.Error, OSError):
        continue
    when = time.strftime("%d.%m.%Y %H:%M", time.localtime(os.path.getmtime(path)))
    print(f"{path}|{when}|{n}|{k}")
PY
}

# Спрашивает, вернуть ли 3x-ui из копии. Итог — в XUI_RESTORE_ARCHIVE
# (пусто — не возвращать). Подходящих копий нет — молчит.
xui_restore_ask() {
    local domain="$1" line path when n k answer
    XUI_RESTORE_ARCHIVE=""
    [ -f "$XUI_RESTORE_TOOL" ] || return 0
    line="$(xui_restore_candidates "$domain" | head -1)"
    [ -n "$line" ] || return 0
    IFS='|' read -r path when n k <<< "$line"
    echo -e "\n${CYAN}Найдена копия 3x-ui для ${domain}.${NC}"
    echo -e "${C_DESC}   $(basename "$path") от ${when}: входящих ${n}, клиентов ${k}."
    echo -e "   Вернуть её — значит получить прежних клиентов, ключи и пути:"
    echo -e "   ссылки у пользователей продолжат работать. Иначе панель будет"
    echo -e "   свежей, и ссылки придётся выдавать заново.${NC}"
    read -r -p "Вернуть 3x-ui из этой копии после установки? [Y/n]: " answer || return 0
    case "$answer" in [Nn]*) return 0 ;; esac
    XUI_RESTORE_ARCHIVE="$path"
}

# Наложить шаблон. Отказ не роняет вызывающего: инструмент сам возвращает
# базу из копии, и панель остаётся свежей установкой — рабочей, просто без
# ваших правок. Такое сообщается, а не прячется.
xui_profile_apply() {
    # Цвета через :- — функцию зовёт и установщик стека, а там set -u и
    # цветов меню нет: голая ссылка уронила бы установку на полпути.
    local domain="$1" reality="$2" name="$3"
    [ -f "$XUI_PROFILE_FILE" ] || { echo -e "${RED:-}❌ Нет шаблона: $XUI_PROFILE_FILE${NC:-}"; return 1; }
    if python3 "$XUI_PROFILE_TOOL" apply --profile "$XUI_PROFILE_FILE" \
            --domain "$domain" --reality-domain "$reality" --name "$name"; then
        return 0
    fi
    echo -e "${YELLOW:-}❗  Шаблон не наложен. Панель работает как свежая установка;"
    echo -e "   наложить можно позже: меню X-UI → «Шаблон настроек».${NC:-}"
    return 1
}
