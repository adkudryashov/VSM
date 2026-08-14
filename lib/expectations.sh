#!/bin/bash

# ======================================================================
# РЕЕСТР РЕШЕНИЙ VSM
#
# VSM не владеет ни одним из компонентов, которыми управляет: MTProxyL,
# 3x-ui-pro, telemt, AmneziaWG — чужие, со своими умолчаниями, выбранными для
# общего случая. Ценность VSM — не скрипты, а РЕШЕНИЯ: осознанные отступления
# от этих умолчаний ради незаметности.
#
# Проблема в том, что решения нигде не записаны как решения. Они существуют
# побочным эффектом установочных скриптов, компонент о них не знает, и любое
# обновление накатывает свои умолчания обратно. За две недели это случилось
# трижды: патч x-ui вычистил маску nginx, панель получила право переписывать
# telemt.toml, слежка вернулась дважды разными путями.
#
# Здесь решения объявлены списком. checks/drift.sh сверяет с ним
# действительность.
#
# ДВА КЛАССА, и разница между ними — цена ошибки:
#
#   fix   Незаметность и безопасность. Чинится молча, о починке сообщается
#         постфактум: цена бездействия здесь выше цены неожиданности.
#   tell  Всё остальное. Показывается и ждёт человека.
#
# ФАЙЛ ИСКЛЮЧЕНИЙ /etc/vsm/expectations.local — строка с id отключает позицию.
# Без него автопочинка спорила бы с намеренными изменениями владельца каждый
# час, и механизм, задуманный как помощь, стал бы невыносимым.
#
# ЭТО ОБНАРУЖЕНИЕ И ВОЗВРАТ, А НЕ ЗАПРЕТ. Помешать чужому обновлению VSM не
# может и не должен: единственный способ — фиксация версий, а она отрезает и
# исправления безопасности.
# ======================================================================

EXPECT_LOCAL="${EXPECT_LOCAL:-/etc/vsm/expectations.local}"
EXPECT_STATE="${EXPECT_STATE:-/etc/vsm/expectations.state}"
MTPL_PANEL_CONF="${MTPL_PANEL_CONF:-/etc/mtproxyl-panel/config.toml}"

# id|класс|заголовок|почему именно так
EXPECTATIONS=(
"panel_listen|fix|Панель MTProxyL слушает только loopback|Наружу панель видна лишь через 443 по секретному префиксу. Открытый порт сводит маскировку на нет: секретный путь не спрячет слушающий сокет."
"panel_tls|fix|У панели MTProxyL нет своего TLS|TLS терминирует nginx сертификатом сайта. Своим TLS панель отдавала бы другой отпечаток на отдельном порту — то есть ровно ту примету, которую мы прячем."
"panel_mtproxyl_off|fix|Панель не управляет самим MTProxyL|Иначе в вебе появляются кнопки переключения маскировки и режимов. Один случайный клик меняет то, на чём держится незаметность."
"panel_config_api|fix|Панель не переписывает telemt.toml|При config_edit_mode=file панель правит файл движка от root. Подмена там снаружи выглядит не как авария, а как исправно работающий, но заметный сервер."
"avail_interval|fix|Проверка доступности раз в 30 минут|Умолчание автора — 15 минут, вдвое больше российских зондов к серверу, который маскируется."
"avail_probes|fix|Проверка доступности по 20 зондов|Число выбрано владельцем: на десяти зондах один непроехавший даёт 10% разброса, на двадцати — 5%."
"nginx_blocks|tell|Блоки VSM в nginx на месте|Установщик и патч 3x-ui-pro чистят /etc/nginx/sites-enabled целиком, унося с собой маску и доступ к обеим панелям."
"panel_prefix|tell|Префикс панели совпадает в nginx и в её конфиге|Разойдутся — страница входа откроется, а все её ресурсы отдадут 404. Ищется такое долго: панель при этом полностью исправна."
"foreign_timers|tell|Новых чужих таймеров не появилось|Именно так дважды возвращалась слежка: обновление MTProxyL приносило свой systemd-таймер, который снова гнал зонды наружу."
"sudoers_grants|tell|Права sudoers у сторонних компонентов не изменились|Новая строка в sudoers.d — это новое право писать от root. Сносить его молча нельзя: сломает чужой софт наглухо. Но знать о нём надо."
)

# ----------------------------------------------------------------------
# Чтение и правка TOML. Своё, а не питон с библиотекой: этот файл читается из
# bash в диагностике, и тащить ради двух ключей отдельный интерпретатор незачем.
# Пустая секция означает верхний уровень — до первого [заголовка].
# ----------------------------------------------------------------------
_toml_get() {
    local file="$1" section="$2" key="$3"
    [ -r "$file" ] || return 0
    awk -v want="$section" -v k="$key" '
        /^[[:space:]]*\[/ {
            cur = $0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
            next
        }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            if (cur == want) {
                line = $0
                sub(/^[^=]*=[[:space:]]*/, "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                sub(/[[:space:]]*$/, "", line)
                gsub(/^"|"$/, "", line)
                print line
                exit
            }
        }
    ' "$file"
}

_toml_set() {
    local file="$1" section="$2" key="$3" value="$4" tmp
    [ -w "$file" ] || return 1
    tmp="$(mktemp)" || return 1
    awk -v want="$section" -v k="$key" -v v="$value" '
        /^[[:space:]]*\[/ {
            cur = $0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
            print; next
        }
        {
            if (cur == want && $0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
                print k " = " v; next
            }
            print
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    # Через cat, а не mv: сохраняем владельца и права исходного файла, у него
    # они 600 и принадлежат root.
    cat "$tmp" > "$file" && rm -f "$tmp"
}

# Резервная копия перед правкой чужого конфига. Одна на прогон: чинить одно и
# то же по десять раз незачем, а потерять исходник — есть чем.
_expect_backup() {
    local file="$1"
    [ -f "$file" ] || return 0
    [ -f "${file}.vsm-before-drift" ] || cp -a "$file" "${file}.vsm-before-drift"
}

expect_excluded() {
    [ -r "$EXPECT_LOCAL" ] || return 1
    grep -qE "^[[:space:]]*$1[[:space:]]*$" "$EXPECT_LOCAL" 2>/dev/null
}

# Запомненное состояние для позиций, у которых «ожидание» — это база сравнения,
# а не константа: список чужих таймеров и права sudoers.
_state_get() {
    [ -r "$EXPECT_STATE" ] || return 0
    grep -m1 -oP "^$1=\K.*" "$EXPECT_STATE" 2>/dev/null
}

_state_set() {
    mkdir -p "$(dirname "$EXPECT_STATE")" 2>/dev/null
    touch "$EXPECT_STATE" 2>/dev/null || return 1
    chmod 600 "$EXPECT_STATE" 2>/dev/null
    if grep -q "^$1=" "$EXPECT_STATE" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$EXPECT_STATE"
    else
        printf '%s=%s\n' "$1" "$2" >> "$EXPECT_STATE"
    fi
}

# ======================================================================
# ПОЗИЦИИ РЕЕСТРА
#
# На каждую: applies_ (есть ли что проверять), want_ (как должно быть),
# read_ (как есть), и для класса fix — fix_ (вернуть как должно).
# applies_ возвращает не-ноль, когда компонент не установлен: это не дрейф,
# это другая установка.
# ======================================================================

# --- Панель MTProxyL --------------------------------------------------
applies_panel_listen() { [ -r "$MTPL_PANEL_CONF" ]; }
want_panel_listen()    { echo "127.0.0.1"; }
read_panel_listen()    { _toml_get "$MTPL_PANEL_CONF" "" listen | sed 's/:[0-9]*$//'; }
fix_panel_listen() {
    local port; port="$(_toml_get "$MTPL_PANEL_CONF" "" listen | sed 's/.*://')"
    [[ "$port" =~ ^[0-9]+$ ]] || port=8080
    _expect_backup "$MTPL_PANEL_CONF"
    _toml_set "$MTPL_PANEL_CONF" "" listen "\"127.0.0.1:${port}\"" || return 1
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

applies_panel_tls() { [ -r "$MTPL_PANEL_CONF" ]; }
want_panel_tls()    { echo "нет"; }
read_panel_tls() {
    grep -qE '^[[:space:]]*\[tls\]' "$MTPL_PANEL_CONF" 2>/dev/null && echo "есть" || echo "нет"
}
fix_panel_tls() {
    local tmp; tmp="$(mktemp)" || return 1
    _expect_backup "$MTPL_PANEL_CONF"
    # Вырезаем секцию целиком: от [tls] до следующего заголовка или конца файла.
    awk '
        /^[[:space:]]*\[tls\]/ { skip = 1; next }
        /^[[:space:]]*\[/      { skip = 0 }
        !skip
    ' "$MTPL_PANEL_CONF" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$MTPL_PANEL_CONF" && rm -f "$tmp"
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

applies_panel_mtproxyl_off() { [ -r "$MTPL_PANEL_CONF" ]; }
want_panel_mtproxyl_off()    { echo "false"; }
read_panel_mtproxyl_off()    { _toml_get "$MTPL_PANEL_CONF" mtproxyl enabled; }
fix_panel_mtproxyl_off() {
    _expect_backup "$MTPL_PANEL_CONF"
    _toml_set "$MTPL_PANEL_CONF" mtproxyl enabled "false" || return 1
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

applies_panel_config_api() { [ -r "$MTPL_PANEL_CONF" ]; }
want_panel_config_api()    { echo "api"; }
read_panel_config_api()    { _toml_get "$MTPL_PANEL_CONF" "" config_edit_mode; }
fix_panel_config_api() {
    _expect_backup "$MTPL_PANEL_CONF"
    _toml_set "$MTPL_PANEL_CONF" "" config_edit_mode "\"api\"" || return 1
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

# --- Проверка доступности в MTProxyL ----------------------------------
_avail_field() {
    command -v mtproxyl >/dev/null 2>&1 || return 0
    mtproxyl availability status --json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null
}

applies_avail_interval() { command -v mtproxyl >/dev/null 2>&1; }
want_avail_interval()    { echo "${VSM_AVAIL_INTERVAL:-30}"; }
read_avail_interval()    { _avail_field interval; }
fix_avail_interval()     { mtproxyl settings set AVAILABILITY_INTERVAL "$(want_avail_interval)" >/dev/null 2>&1; }

applies_avail_probes() { command -v mtproxyl >/dev/null 2>&1; }
want_avail_probes()    { echo "${VSM_AVAIL_PROBES:-20}"; }
read_avail_probes()    { _avail_field probes; }
fix_avail_probes()     { mtproxyl settings set AVAILABILITY_PROBES "$(want_avail_probes)" >/dev/null 2>&1; }

# --- nginx ------------------------------------------------------------
# Класс tell, а не fix, СОЗНАТЕЛЬНО. Автопочинка потребовала бы заново собрать
# тот же контекст, что собирает пункт 4 «Восстановить nginx»: домен, порт,
# префиксы обеих панелей. Две реализации одного восстановления рано или поздно
# разойдутся — а это ровно тот класс ошибок, ради которого весь реестр и
# затевался. Поэтому здесь громкий отчёт и указание на единственный
# проверенный путь.
# Читаем файл напрямую, а не через conf_get_stack: та функция живёт внутри
# stacks/bots.sh, и тянуть сюда установщик ради одного значения незачем.
VSM_TELEMT_CONF="${VSM_TELEMT_CONF:-/etc/vsm/telemt.conf}"
_panel_domain() {
    [ -r "$VSM_TELEMT_CONF" ] || return 0
    grep -m1 -oP '^DOMAIN_PANEL=\K.*' "$VSM_TELEMT_CONF" 2>/dev/null | tr -d "'\""
}

applies_nginx_blocks() {
    [ -n "$(_panel_domain)" ] && command -v nginx >/dev/null 2>&1
}
want_nginx_blocks() { echo "на месте"; }
read_nginx_blocks() {
    local vhost; vhost="$(nginx_mask_panel_vhost "$(_panel_domain)" 2>/dev/null)"
    [ -r "$vhost" ] || { echo "vhost не найден"; return 0; }
    grep -q "$PANEL_PROXY_BEGIN" "$vhost" 2>/dev/null && echo "на месте" || echo "блок панели пропал"
}

applies_panel_prefix() { [ -r "$MTPL_PANEL_CONF" ] && [ -n "$(_panel_domain)" ]; }
want_panel_prefix()    { mtpl_panel_prefix 2>/dev/null; }
read_panel_prefix() {
    local vhost prefix
    vhost="$(nginx_mask_panel_vhost "$(_panel_domain)" 2>/dev/null)"
    [ -r "$vhost" ] || { echo "vhost не найден"; return 0; }
    prefix="$(sed -n "/${MTPL_PROXY_BEGIN//\//\\/}/,/${MTPL_PROXY_END//\//\\/}/s|^[[:space:]]*location /\([A-Za-z0-9_-]*\)/.*|\1|p" "$vhost" 2>/dev/null | head -1)"
    echo "${prefix:-блока MTProxyL-Panel нет}"
}

# --- Чужие таймеры и права -------------------------------------------
applies_foreign_timers() { command -v systemctl >/dev/null 2>&1; }
want_foreign_timers()    { _state_get foreign_timers; }
read_foreign_timers() {
    systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
        | awk '{print $NF}' | grep -vE '^(systemd-|apt-|dpkg-|man-db|logrotate|fstrim|e2scrub)' \
        | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

applies_sudoers_grants() { [ -d /etc/sudoers.d ]; }
want_sudoers_grants()    { _state_get sudoers_grants; }
read_sudoers_grants() {
    # Считаем не содержимое, а отпечаток: строки с путями и правами длинные, и
    # в отчёте от них толку меньше, чем от факта «изменилось».
    cat /etc/sudoers.d/* 2>/dev/null | grep -vE '^\s*(#|$)' | sort | sha256sum | cut -c1-12
}
