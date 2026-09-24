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
