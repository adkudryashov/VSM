#!/bin/bash

# ======================================================================
# РЕЕСТР РЕШЕНИЙ VSM
#
# VSM не владеет ни одним из компонентов, которыми управляет: MTProxyL,
# 3x-ui-pro, telemt, MTProxyL-Panel — чужие, со своими умолчаниями, выбранными для
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
# Права root, которые установщик панели выдаёт ей на управление MTProxyL.
# Отдельным файлом от основных прав — и он же сам его удаляет, когда
# интеграция выключена. Мы пользуемся тем же файлом и той же семантикой.
MTPL_PANEL_SUDOERS="${MTPL_PANEL_SUDOERS:-/etc/sudoers.d/mtproxyl-panel-mtproxyl}"
TELEMT_TOML="${TELEMT_TOML:-/etc/telemt/telemt.toml}"
# Конфиг стека VSM: там записаны решения, принятые при развёртывании, — домен
# панели и порт маски. Читаем файл напрямую, а не через conf_get_stack: та
# функция живёт внутри stacks/bots.sh, и тянуть сюда установщик ради двух
# значений незачем.
VSM_TELEMT_CONF="${VSM_TELEMT_CONF:-/etc/vsm/telemt.conf}"

# id|класс|заголовок|почему именно так
EXPECTATIONS=(
"panel_listen|fix|Панель MTProxyL слушает только loopback|Наружу панель видна лишь через 443 по секретному префиксу. Открытый порт сводит маскировку на нет: секретный путь не спрячет слушающий сокет."
"panel_tls|fix|У панели MTProxyL нет своего TLS|TLS терминирует nginx сертификатом сайта. Своим TLS панель отдавала бы другой отпечаток на отдельном порту — то есть ровно ту примету, которую мы прячем."
"panel_mtproxyl_off|fix|Панель не управляет самим MTProxyL|Иначе в вебе появляются кнопки переключения маскировки и режимов. Один случайный клик меняет то, на чём держится незаметность."
"panel_config_api|fix|Панель не переписывает telemt.toml|При config_edit_mode=file панель правит файл движка от root. Подмена там снаружи выглядит не как авария, а как исправно работающий, но заметный сервер."
"panel_rights_live|tell|Права панели MTProxyL действуют, а не отвергнуты|Установщик панели пишет правила с символом * в аргументах, а sudo-rs из Ubuntu 26+ такие файлы отвергает целиком. Панель при этом открывается и выглядит исправной, но её кнопки пусты: ни перезапуска telemt, ни журналов, ни своего обновления. Тихая потеря возможностей, которую видно только по неработающей кнопке."
"telemt_mask|fix|Маскировка telemt направлена на локальный nginx|Это ядро незаметности: на чужой пробы отвечает сайт с настоящим сертификатом, а не прокси. Установщик telemt ставит свои умолчания, и запустить его может кто угодно — пункт VSM, MTProxyL, её панель. Возврат требует перезапуска telemt: без него файл говорит одно, а движок работает по-старому."
"avail_interval|fix|Проверка доступности раз в 30 минут|Умолчание автора — 15 минут, вдвое больше российских зондов к серверу, который маскируется."
"avail_probes|fix|Проверка доступности по 20 зондов|Число выбрано владельцем: на десяти зондах один непроехавший даёт 10% разброса, на двадцати — 5%."
"nginx_blocks|tell|Блоки VSM в nginx на месте|Установщик и патч 3x-ui-pro чистят /etc/nginx/sites-enabled целиком, унося с собой маску и доступ к обеим панелям."
"panel_prefix|tell|Префикс панели совпадает в nginx и в её конфиге|Разойдутся — страница входа откроется, а все её ресурсы отдадут 404. Ищется такое долго: панель при этом полностью исправна."
"journal_limits|tell|Настройка журналирования, сделанная вами, на месте|Без потолка журнал занимает 10% диска просто потому, что место было, а дублирование в syslog пишет одно и то же дважды: на сервере с прокси это сотни мегабайт в сутки. Возвращаем НЕ молча — журналирование общесистемное, и решать за вас VSM тут не должен."
"foreign_timers|tell|Новых чужих таймеров не появилось|Именно так дважды возвращалась слежка: обновление MTProxyL приносило свой systemd-таймер, который снова гнал зонды наружу."
"sudoers_grants|tell|Права sudoers у сторонних компонентов не изменились|Новая строка в sudoers.d — это новое право писать от root. Сносить его молча нельзя: сломает чужой софт наглухо. Но знать о нём надо."
"orphan_panel_rights|fix|Нет прав root у панели, которой нет|Учётная запись панели переживает её удаление, а права при ней продолжают работать: запись в конфиг прокси от root и подмена самого бинаря telemt. Панели нет — значит и права не нужны никому."
"panels_single|tell|Веб-панель на сервере одна|Две админки — вдвое больше того, что можно взломать и надо обновлять, ради одной задачи. Страж VSM стоит перед установкой, но чужую панель ставят и её собственной командой — мимо него."
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

# Ключа в секции может не оказаться вовсе: чужое обновление вправе не только
# поменять значение, но и выбросить строку целиком. Прежняя версия умела лишь
# ЗАМЕНЯТЬ существующую, поэтому на выброшенном ключе тихо ничего не делала —
# сверка вечно докладывала бы «починить не удалось». Поэтому ключ, не найденный
# в нужной секции, дописывается в её конец.
#
# Секцию, которой в файле нет, НЕ создаём: это уже не возврат нашего решения, а
# переустройство чужого конфига вслепую. Такой случай честно доедет до отчёта.
_toml_set() {
    local file="$1" section="$2" key="$3" value="$4" tmp dst
    [ -w "$file" ] || return 1
    tmp="$(mktemp)" || return 1
    awk -v want="$section" -v k="$key" -v v="$value" '
        BEGIN { cur = ""; done = 0 }
        /^[[:space:]]*\[/ {
            # Уходим из нужной секции, так и не встретив ключа — дописываем.
            if (cur == want && !done) { print k " = " v; done = 1 }
            cur = $0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", cur)
            print; next
        }
        {
            if (cur == want && !done && $0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
                print k " = " v; done = 1; next
            }
            print
        }
        END { if (cur == want && !done) print k " = " v }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    _atomic_replace "$file" "$tmp"
}

# Подмена содержимого файла переименованием, а не «cat во владение».
#
# Прежние версии писали `cat "$tmp" > "$file"`, то есть УСЕКАЛИ чужой конфиг
# первой же командой ради сохранения владельца и прав. Сорвись запись на
# полпути (диск полон, ФС ушла в read-only) — и следующая строка починки
# перезапускала бы службу на обрубке. Ровно этот урок уже усвоен в
# lib/config.sh для xui.conf; сюда идиома вернулась незамеченной.
#
# Временный файл создаётся РЯДОМ с целевым: mv через границу файловых систем
# вырождается в копирование, то есть в то же усечение. Права и владельца
# переносим с оригинала — у него 600 и root.
#
# Забирает src: он удаляется в любом исходе.
_atomic_replace() {
    local file="$1" src="$2" dst
    dst="$(mktemp "${file}.vsm.XXXXXX")" || { rm -f "$src"; return 1; }
    chmod --reference="$file" "$dst" 2>/dev/null
    chown --reference="$file" "$dst" 2>/dev/null
    if ! cat "$src" > "$dst"; then
        rm -f "$src" "$dst"; return 1
    fi
    rm -f "$src"
    mv -f "$dst" "$file" || { rm -f "$dst"; return 1; }
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
# Применима ли позиция, настраивающая MTProxyL-Panel.
#
# Мало прочитать её конфиг: конфиг переживает неудачную установку. На приёмке
# 27.08.2026 установщик панели упал на генерации sudoers, оставив бинарь и
# config.toml без юнита, — и четыре позиции немедленно потребовали настроек от
# службы, которой нет. Одна из них класса fix, то есть правила бы конфиг
# несуществующей панели и перезапускала бы её же.
#
# Спрашиваем и про службу тоже. Без lib/panels.sh не додумываем: проверяем как
# раньше, по одному конфигу.
_mtpl_panel_configurable() {
    [ -r "$MTPL_PANEL_CONF" ] || return 1
    declare -F panel_mtproxyl_installed >/dev/null 2>&1 || return 0
    panel_mtproxyl_installed
}

applies_panel_listen() { _mtpl_panel_configurable; }
want_panel_listen()    { echo "127.0.0.1"; }
read_panel_listen()    { _toml_get "$MTPL_PANEL_CONF" "" listen | sed 's/:[0-9]*$//'; }
fix_panel_listen() {
    local port; port="$(_toml_get "$MTPL_PANEL_CONF" "" listen | sed 's/.*://')"
    [[ "$port" =~ ^[0-9]+$ ]] || port=8080
    _expect_backup "$MTPL_PANEL_CONF"
    _toml_set "$MTPL_PANEL_CONF" "" listen "\"127.0.0.1:${port}\"" || return 1
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

applies_panel_tls() { _mtpl_panel_configurable; }
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
    _atomic_replace "$MTPL_PANEL_CONF" "$tmp" || return 1
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

# Смотрим на ДВА факта, а не на один.
#
# Первая версия проверяла только флаг в конфиге — и этого мало. Флаг убирает
# кнопки из веб-интерфейса, но права root у панели остаются: сотня строк в
# sudoers.d, среди них смена режима MTProxyL и `selfmask disable`, то есть
# снятие маскировки. Панель сама решает, звать ли sudo; если её взломают,
# наш флаг в её же конфиге не значит ничего, а права — значат всё.
#
# Поймано установкой панели на стенде: реестр честно вернул enabled = false,
# отчитался «починено», а файл прав остался нетронутым.
#
# Удаление файла — не самодеятельность: установщик панели удаляет ровно его и
# ровно при enabled = false. Мы приводим систему к тому же состоянию, к
# которому её привёл бы он сам, просто не дожидаясь переустановки.
applies_panel_mtproxyl_off() { _mtpl_panel_configurable; }
want_panel_mtproxyl_off()    { echo "false"; }
read_panel_mtproxyl_off() {
    local enabled; enabled="$(_toml_get "$MTPL_PANEL_CONF" mtproxyl enabled)"
    if [ "$enabled" != "false" ]; then
        echo "${enabled:-пусто}"
        return 0
    fi
    if [ -e "$MTPL_PANEL_SUDOERS" ]; then
        echo "false, но права root на месте"
        return 0
    fi
    echo "false"
}
fix_panel_mtproxyl_off() {
    _expect_backup "$MTPL_PANEL_CONF"
    _toml_set "$MTPL_PANEL_CONF" mtproxyl enabled "false" || return 1
    rm -f "$MTPL_PANEL_SUDOERS"
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

applies_panel_config_api() { _mtpl_panel_configurable; }
want_panel_config_api()    { echo "api"; }
# Ключ лежит в секции [telemt], а не на верхнем уровне. Первый прогон сверки
# читал его сверху, получал пустоту и объявлял дрейф на исправной установке —
# ровно тот ложный сигнал, от которого перестают верить всей проверке.
read_panel_config_api()    { _toml_get "$MTPL_PANEL_CONF" telemt config_edit_mode; }
fix_panel_config_api() {
    _expect_backup "$MTPL_PANEL_CONF"
    _toml_set "$MTPL_PANEL_CONF" telemt config_edit_mode "\"api\"" || return 1
    systemctl restart mtproxyl-panel >/dev/null 2>&1
}

# --- Брошенные права удалённой панели ---------------------------------
#
# Найдено при разборе обновления MTProxyL: на стенде лежал
# /etc/sudoers.d/telemt-panel — 19 строк NOPASSWD от панели, снесённой ещё в
# прошлом прогоне. Ни бинаря, ни юнита, ни каталога; а пользователь
# telemt-panel в системе остался, и права при нём работали. Среди них
# `tee /etc/telemt/telemt.toml` — запись в конфиг прокси от root — и подмена
# /bin/telemt через cp с последующим mv.
#
# Удаление панели теперь снимает права само (lib/panels.sh). Позиция нужна
# всё равно: файл кладёт ЧУЖОЙ установщик, и он же вернёт его при следующем
# обновлении telemt — ровно то повторяющееся возвращение чужих умолчаний,
# ради которого весь реестр и заведён.
#
# Класс fix: это безопасность, а удалять права несуществующей панели безопасно
# по определению — ломать нечего.
_orphan_rights_files() {
    local out=()
    # _present, а не _installed: права снимаются молча, а молча снятое право —
    # это сломанная наглухо чужая служба. Пока файлы панели лежат, считаем, что
    # хозяин у прав есть. Настоящую брошенность видно, когда не осталось ничего.
    panel_telemt_present   || [ ! -e "$TELEMT_PANEL_SUDOERS" ] || out+=("$TELEMT_PANEL_SUDOERS")
    if ! panel_mtproxyl_present; then
        local f
        for f in "${MTPL_PANEL_SUDOERS_FILES[@]}"; do
            [ -e "$f" ] && out+=("$f")
        done
    fi
    [ "${#out[@]}" -eq 0 ] || printf '%s
' "${out[@]}"
}

applies_orphan_panel_rights() {
    declare -F panel_telemt_present >/dev/null 2>&1 || return 1
    [ -d /etc/sudoers.d ]
}
want_orphan_panel_rights() { echo "нет"; }
read_orphan_panel_rights() {
    local found; found="$(_orphan_rights_files)"
    if [ -z "$found" ]; then
        echo "нет"
    else
        # Имена файлов, а не количество: убирать их человеку, возможно, руками,
        # если сверка почему-то не смогла.
        echo "есть: $(printf '%s' "$found" | xargs -r -n1 basename | tr '
' ' ' | sed 's/ $//')"
    fi
}
fix_orphan_panel_rights() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f"
    done <<< "$(_orphan_rights_files)"
    [ -z "$(_orphan_rights_files)" ]
}

# --- Одна панель на сервер --------------------------------------------
#
# Страж lib/panels.sh спрашивает перед установкой — но только на путях VSM.
# MTProxyL-Panel ставится и своей командой `mtproxyl panel install`, а
# telemt_panel приезжает вместе с чужим установщиком telemt: оба пути мимо нас,
# и запретить им VSM ничего не может. Поэтому здесь не запрет, а обнаружение —
# ровно как со всем остальным в этом реестре.
#
# Класс tell, и иначе быть не может: молча снести панель значит унести вместе с
# ней учётные данные, которые больше неоткуда взять, и секретный префикс, по
# которому кто-то прямо сейчас работает. Это решение человека, а не сверки.
#
# applies_ требует хотя бы одной: на установке вовсе без панелей вопрос
# «сколько их» не имеет смысла, и позиция обязана молчать.
applies_panels_single() {
    declare -F panel_telemt_present >/dev/null 2>&1 || return 1
    panel_telemt_present || panel_mtproxyl_present
}
want_panels_single() { echo "одна"; }
# Считаем по файлам, а не по службам: недоустановленная панель занимает те же
# пути и те же имена, и «панелей одна» при двух наборах файлов было бы неправдой.
read_panels_single() {
    local found=()
    panel_telemt_present   && found+=("telemt_panel")
    panel_mtproxyl_present && found+=("MTProxyL-Panel")
    if [ "${#found[@]}" -le 1 ]; then
        echo "одна"
    else
        echo "две: ${found[*]}"
    fi
}

# --- Маскировка самого telemt -----------------------------------------
#
# ПОЧЕМУ ЭТО ЗДЕСЬ, А НЕ ОТПЕЧАТОК НА УСТАНОВЩИК. Установщик telemt тянут с
# ветки main и запускают от root минимум три разных пути: пункт VSM
# (stacks/telemt.sh), MTProxyL (её lib/detect.sh дёргает ТОТ ЖЕ адрес) и
# веб-панель. Отпечаток в lib/deps.sh закрывает только первый — два других
# принадлежат чужому софту, и запретить им VSM ничего не может. Реестр же
# смотрит не на путь, а на РЕЗУЛЬТАТ, поэтому ловит все три разом.

# ----------------------------------------------------------------------
# ПРАВА ПАНЕЛИ ДЕЙСТВУЮТ, А НЕ ОТВЕРГНУТЫ
#
# Установщик MTProxyL-Panel выдаёт ей права правилами вида
#   journalctl -u telemt -n * --no-pager
# то есть с символом * в аргументе. Классический sudo такое понимает, а sudo-rs
# — реализация по умолчанию в Ubuntu 26+ — нет: он отвергает ВЕСЬ файл и
# сообщает об этом строкой при каждом вызове sudo.
#
# Проверено фактом 27.08.2026: остальной sudoers при этом продолжает работать,
# права root целы, система жива. Ломается только панель, и ломается тихо — она
# открывается, показывает страницы, но перезапуск telemt, чтение журналов и
# собственное обновление у неё молча перестают работать. По внешнему виду не
# отличить от исправной.
#
# Попасть в это состояние можно двумя путями: переключить sudo обратно на
# sudo-rs (update-alternatives --auto sudo) или обновить панель, когда автор
# добавит новое правило с *. Оба — не аварии, а последствия чужих решений, о
# которых надо просто знать.
#
# Класс tell, и иначе нельзя: починка означает подмену системной реализации
# sudo. Это решение владельца, а не сверки.
#
# Спрашиваем visudo, а не сравниваем версии: реализация — примета, а факт — это
# принят файл или отвергнут. Нет visudo — говорим об этом прямо, а не молчим.
applies_panel_rights_live() {
    declare -F panel_mtproxyl_installed >/dev/null 2>&1 || return 1
    panel_mtproxyl_installed || return 1
    local f
    for f in "${MTPL_PANEL_SUDOERS_FILES[@]}"; do
        [ -e "$f" ] && return 0
    done
    return 1
}
want_panel_rights_live() { echo "действуют"; }
read_panel_rights_live() {
    local v f
    v="$(command -v visudo 2>/dev/null)" || true
    [ -n "$v" ] || { echo "проверить нечем — нет visudo"; return 0; }
    for f in "${MTPL_PANEL_SUDOERS_FILES[@]}"; do
        [ -e "$f" ] || continue
        "$v" -cf "$f" >/dev/null 2>&1 || { echo "отвергнуты"; return 0; }
    done
    echo "действуют"
}

# Порт маски — не константа: он свой на каждой установке и записан в конфиг
# стека при развёртывании. Брать его из живого telemt.toml нельзя, иначе
# эталоном стало бы то самое значение, которое мы проверяем.
_mask_port() {
    [ -r "$VSM_TELEMT_CONF" ] || return 0
    grep -m1 -oP '^TELEMT_MASK_PORT=\K.*' "$VSM_TELEMT_CONF" 2>/dev/null | tr -dc '0-9'
}

applies_telemt_mask() { [ -r "$TELEMT_TOML" ] && [ -n "$(_mask_port)" ]; }
want_telemt_mask()    { printf 'true 127.0.0.1 %s' "$(_mask_port)"; }
read_telemt_mask() {
    printf '%s %s %s' \
        "$(_toml_get "$TELEMT_TOML" censorship mask)" \
        "$(_toml_get "$TELEMT_TOML" censorship mask_host)" \
        "$(_toml_get "$TELEMT_TOML" censorship mask_port)"
}
# Три ключа одной позицией, а не тремя: это одно решение, и чинятся они вместе.
# Тремя строками отчёт об одной поломке выглядел бы как три разные аварии.
fix_telemt_mask() {
    local port; port="$(_mask_port)"
    [ -n "$port" ] || return 1
    _expect_backup "$TELEMT_TOML"
    _toml_set "$TELEMT_TOML" censorship mask true || return 1
    _toml_set "$TELEMT_TOML" censorship mask_host '"127.0.0.1"' || return 1
    _toml_set "$TELEMT_TOML" censorship mask_port "$port" || return 1
    # Перезапуск ТОЛЬКО если файл действительно стал таким, каким нужен.
    #
    # Иначе при устойчивой неудаче (секции censorship в файле нет, права ушли)
    # сверка дёргала бы telemt каждый час без всякого толка, обрывая соединения
    # живым пользователям. Перезапуск здесь дорог — это единственная позиция
    # реестра, которая трогает сам прокси, а не панель.
    [ "$(read_telemt_mask)" = "$(want_telemt_mask)" ] || return 1
    systemctl restart telemt >/dev/null 2>&1
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
# тот же контекст, что собирает пункт «Восстановить nginx»: домен, порт,
# префиксы обеих панелей. Две реализации одного восстановления рано или поздно
# разойдутся — а это ровно тот класс ошибок, ради которого весь реестр и
# затевался. Поэтому здесь громкий отчёт и указание на единственный
# проверенный путь.
_panel_domain() {
    [ -r "$VSM_TELEMT_CONF" ] || return 0
    grep -m1 -oP '^DOMAIN_PANEL=\K.*' "$VSM_TELEMT_CONF" 2>/dev/null | tr -d "'\""
}

# Блок в nginx ведёт НА ПАНЕЛЬ. Нет ни одной — вести некуда, и отсутствие
# блока это не пропажа, а установка без панели.
#
# Поймано прогоном удаления на стенде: сняли обе панели, и позиция немедленно
# объявила расхождение на совершенно исправной системе. Ровно тот ложный
# сигнал, после которого перестают верить всей проверке.
applies_nginx_blocks() {
    [ -n "$(_panel_domain)" ] || return 1
    command -v nginx >/dev/null 2>&1 || return 1
    # Функции из lib/panels.sh. Если библиотека не подключена — не додумываем
    # и проверяем как раньше: лучше лишний вопрос, чем молчание о пропаже.
    if declare -F panel_telemt_installed >/dev/null 2>&1; then
        panel_telemt_installed || panel_mtproxyl_installed || return 1
    fi
    return 0
}
want_nginx_blocks() { echo "на месте"; }
# Ищем блок ТОЙ панели, которая на сервере есть.
#
# Первая версия смотрела только на блок telemt_panel. Пока панели уживались
# рядом, это работало; после правила «одна панель на сервер» позиция начала
# требовать блок несуществующей панели и объявляла пропажу на установке, где
# MTProxyL-Panel подключена и отвечает 200. Ровно тот ложный сигнал, ради
# отсутствия которого applies_nginx_blocks и учили спрашивать про панели.
#
# Пропажу называем поимённо: «пропал блок telemt_panel» и «пропал блок
# MTProxyL-Panel» чинятся одним и тем же пунктом меню, но искать причину, если
# он не помог, придётся в разных местах.
read_nginx_blocks() {
    local vhost missing=()
    vhost="$(nginx_mask_panel_vhost "$(_panel_domain)" 2>/dev/null)"
    [ -r "$vhost" ] || { echo "vhost не найден"; return 0; }

    # Без lib/panels.sh не додумываем и проверяем как раньше: лучше лишний
    # вопрос, чем молчание о настоящей пропаже.
    if ! declare -F panel_telemt_installed >/dev/null 2>&1; then
        grep -q "$PANEL_PROXY_BEGIN" "$vhost" 2>/dev/null \
            && echo "на месте" || echo "блок панели пропал"
        return 0
    fi

    if panel_telemt_installed && ! grep -q "$PANEL_PROXY_BEGIN" "$vhost" 2>/dev/null; then
        missing+=("telemt_panel")
    fi
    if panel_mtproxyl_installed && ! grep -q "$MTPL_PROXY_BEGIN" "$vhost" 2>/dev/null; then
        missing+=("MTProxyL-Panel")
    fi
    if [ "${#missing[@]}" -eq 0 ]; then
        echo "на месте"
    else
        echo "пропал блок: ${missing[*]}"
    fi
}

applies_panel_prefix() { _mtpl_panel_configurable && [ -n "$(_panel_domain)" ]; }
want_panel_prefix()    { mtpl_panel_prefix 2>/dev/null; }
read_panel_prefix() {
    local vhost prefix
    vhost="$(nginx_mask_panel_vhost "$(_panel_domain)" 2>/dev/null)"
    [ -r "$vhost" ] || { echo "vhost не найден"; return 0; }
    prefix="$(sed -n "/${MTPL_PROXY_BEGIN//\//\\/}/,/${MTPL_PROXY_END//\//\\/}/s|^[[:space:]]*location /\([A-Za-z0-9_-]*\)/.*|\1|p" "$vhost" 2>/dev/null | head -1)"
    echo "${prefix:-блока MTProxyL-Panel нет}"
}

# --- Журналирование ---------------------------------------------------
#
# Класс tell, а не fix, и это принципиально. Всё остальное в реестре — решения
# ВНУТРИ того, чем VSM управляет: своя маскировка, своя панель, свой nginx.
# Журналирование общесистемное и касается всего, что на сервере есть. Молча
# возвращать его — значит вести себя ровно так, как ведут себя чужие
# обновления, за которыми этот реестр и следит.
#
# applies_ смотрит на ЗАПОМНЕННОЕ РЕШЕНИЕ, а не на наличие файла.
#
# Первая версия проверяла файл — и провалила собственный контрольный случай:
# стоило файл убрать, позиция отвечала «компонент не установлен» и замолкала.
# То есть ровно в том случае, ради которого заводилась (чужое обновление
# снесло настройку), она молчала. Отметку ставит меню при включении и снимает
# при откате, поэтому осознанное выключение владельцем расхождением не станет,
# а исчезновение файла само по себе — станет.
JOURNAL_DROPIN="${JOURNAL_DROPIN:-/etc/systemd/journald.conf.d/zz-vsm.conf}"

applies_journal_limits() { [ "$(_state_get journal_limits)" = "on" ]; }
want_journal_limits()    { echo "потолок и без дублирования"; }
read_journal_limits() {
    # Смотрим на РАЗОБРАННЫЙ конфиг, а не на свой файл: настройку могли
    # перебить другим drop-in с именем позже по алфавиту, и тогда наш файл на
    # месте, а действует не он.
    local cfg cap fwd
    cfg="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null)"
    cap="$(printf '%s' "$cfg" | grep -c '^SystemMaxUse=')"
    fwd="$(printf '%s' "$cfg" | grep -c '^ForwardToSyslog=no')"
    if [ "$cap" -gt 0 ] && [ "$fwd" -gt 0 ]; then
        echo "потолок и без дублирования"
    elif [ "$fwd" -gt 0 ]; then
        echo "без дублирования, но потолок снят"
    elif [ "$cap" -gt 0 ]; then
        echo "потолок есть, дублирование вернулось"
    else
        echo "сброшено к умолчаниям"
    fi
}

# --- Чужие таймеры и права -------------------------------------------
applies_foreign_timers() { command -v systemctl >/dev/null 2>&1; }
want_foreign_timers()    { _state_get foreign_timers; }
read_foreign_timers() {
    # vsm- в списке исключений наравне со штатными системными: позиция ловит
    # ЧУЖИЕ таймеры, а свой собственный — не находка. Поймано на живом
    # примере: добавление vsm-heartbeat.timer немедленно подняло расхождение,
    # то есть VSM пожаловался владельцу сам на себя.
    systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
        | awk '{print $NF}' | grep -vE '^(vsm-|systemd-|apt-|dpkg-|man-db|logrotate|fstrim|e2scrub)' \
        | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

applies_sudoers_grants() { [ -d /etc/sudoers.d ]; }
want_sudoers_grants()    { _state_get sudoers_grants; }
read_sudoers_grants() {
    # Считаем не содержимое, а отпечаток: строки с путями и правами длинные, и
    # в отчёте от них толку меньше, чем от факта «изменилось».
    cat /etc/sudoers.d/* 2>/dev/null | grep -vE '^\s*(#|$)' | sort | sha256sum | cut -c1-12
}
