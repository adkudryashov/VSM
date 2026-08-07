#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Пересборка nginx с OpenSSL 3.5.x (постквантовый TLS, X25519MLKEM768)
#
# ЗАЧЕМ: системный OpenSSL на Ubuntu 24.04 — 3.0.13, гибридный постквантовый
# обмен ключей не поддерживает. Клиенты iOS предпочитают PQ-рукопожатие;
# его отсутствие на self-SNI backend'е — заметный маркер для DPI-эвристик.
# Собираем nginx со СВОИМ OpenSSL 3.5.x, системный не трогаем (от него
# зависят apt/ssh/остальные пакеты).
#
# ВАЖНО: долго (20-40 минут на 1 vCPU) — запускай в tmux/screen.
#
# DRY_RUN=1 — показать, какие модули будут вырезаны, какие оставлены и с
# какими флагами пойдёт ./configure, после чего выйти, ничего не изменив.
# Операция необратимая и длинная, её решения стоит увидеть заранее.
# ============================================================================

OPENSSL_VER="${OPENSSL_VER:-3.5.6}"
NGINX_VER="${NGINX_VER:-}"
DRY_RUN="${DRY_RUN:-0}"

# Префикс своего OpenSSL. Его же ищет _pq_openssl_bin в menu_telemt.sh, когда
# решает, можно ли проверить постквантовый обмен пунктом «Сверить TLS маски и
# панели»: путь здесь и там обязан совпадать.
OPENSSL_PREFIX=/opt/openssl-3.5

log()  { echo -e "\e[1;32m[этап]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m    $*"; }
die()  { echo -e "\e[1;31m[СБОЙ]\e[0m $*" >&2; exit 1; }

# Повторяет команду раз в секунду, пока та не вернёт 0. Двойник функции из
# telemt-stack.sh: скрипт самодостаточен и общий слой меню не подключает.
# Нужна там, где systemd уже отдал управление, а служба ещё дозапускается.
wait_until() {
    local tries="$1"; shift
    local i
    for ((i = 1; i <= tries; i++)); do
        if "$@"; then return 0; fi
        sleep 1
    done
    return 1
}

[[ "$(id -u)" -eq 0 ]] || die "Запускай под root."
command -v nginx >/dev/null || die "nginx не установлен."

[[ -n "$NGINX_VER" ]] || NGINX_VER="$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')"
[[ -n "$NGINX_VER" ]] || die "Не удалось определить версию nginx."

AVAIL_MB="$(df -Pm /usr/local/src | awk 'NR==2 {print $4}')"
[[ "${AVAIL_MB:-0}" -ge 2048 ]] || die "Нужно минимум 2 ГБ свободного места в /usr/local/src (доступно ${AVAIL_MB} МБ)."

# Конфиг обязан быть валиден ДО сборки. Иначе единственной проверкой станет
# `nginx -t` уже после подмены бинарника — то есть о поломке мы узнаем через
# 20-40 минут, отработает откат, и весь прогон окажется впустую.
nginx -t >/dev/null 2>&1 || die "Текущий nginx -t не проходит. Почини конфиг до пересборки — иначе сборка гарантированно закончится откатом."

log "Пересборка nginx ${NGINX_VER} с OpenSSL ${OPENSSL_VER}"

# ---------------------------------------------------------------------------
# Разбор текущих флагов сборки.
# Модули берём из реальной установки, а не из захардкоженного списка:
# иначе модуль, которого нет в списке (brotli, geoip2, nginx-extras...),
# молча теряется, а конфиг с его директивой перестаёт проходить nginx -t.
# ---------------------------------------------------------------------------
CURRENT_ARGS="$(nginx -V 2>&1 | grep 'configure arguments:' | sed 's/.*configure arguments: //')"
[[ -n "$CURRENT_ARGS" ]] || die "Не удалось прочитать configure-флаги текущего nginx."

# Сохраняем hardening-флаги дистрибутива (-fstack-protector-strong,
# -D_FORTIFY_SOURCE=2, PIE/relro): без них пересобранный nginx защищён
# слабее пакетного, а он первым принимает весь трафик из интернета.
CC_OPT="$(sed -n "s/.*--with-cc-opt='\([^']*\)'.*/\1/p" <<< "$CURRENT_ARGS")"
LD_OPT="$(sed -n "s/.*--with-ld-opt='\([^']*\)'.*/\1/p" <<< "$CURRENT_ARGS")"

# Сначала вырезаем закавыченные --with-cc-opt='...' / --with-ld-opt='...'
# ЦЕЛИКОМ. Если этого не сделать, разбиение по пробелам разорвёт значения
# в кавычках, и обрывки вроде "-O2" или "-Wl,-z,relro" попадут в configure
# как самостоятельные (несуществующие) опции.
STRIPPED="$(sed -e "s/--with-cc-opt='[^']*'//g" -e "s/--with-ld-opt='[^']*'//g" <<< "$CURRENT_ARGS")"

# Из остатка выкидываем прежний --with-openssl и динамические модули
# (=dynamic) — их пересобираем статически, отдельные .so здесь неприменимы.
BUILD_ARGS="$(tr ' ' '\n' <<< "$STRIPPED" \
    | grep -v -- "--with-openssl" \
    | grep -v -- "=dynamic" \
    | grep -v '^$' | tr '\n' ' ')"

DYNAMIC_MODS="$(tr ' ' '\n' <<< "$STRIPPED" | grep -- "=dynamic" || true)"
if [[ -n "$DYNAMIC_MODS" ]]; then
    warn "Эти модули собраны динамически и будут встроены статически:"
    sed 's/^/    /' <<< "$DYNAMIC_MODS"
    # Динамические превращаем в статические (убираем =dynamic)
    BUILD_ARGS+=" $(sed 's/=dynamic$//' <<< "$DYNAMIC_MODS" | tr '\n' ' ')"
fi

log "Флаги сборки взяты из nginx -V."

# ---------------------------------------------------------------------------
# Отбор модулей, которые стеку не нужны.
#
# ЗАЧЕМ: пакет nginx ставит рантайм-библиотеки, а исходная сборка модуля
# требует ещё и заголовки. Перевод динамических модулей в статические (выше)
# тянет эти зависимости за собой, и скрипт падал на самом первом из них:
#   ./configure: error: the HTTP XSLT module requires the libxml2/libxslt
# Ровно поэтому пересборка не проходила ни разу.
#
# Вырезать вслепую нельзя: комментарий выше объясняет, почему модули берутся
# из реальной установки, а не из списка, — тот же довод действует и здесь.
# Поэтому решение принимается ПО ФАКТУ: если директива модуля встречается в
# ЭФФЕКТИВНОМ конфиге (nginx -T, а не один файл — include развернётся сам),
# модуль остаётся, и ему доставляется зависимость сборки.
#
# Греп идёт по всему выводу, включая комментарии. Направление ошибки выбрано
# намеренно: ложное «используется» стоит одного лишнего пакета, ложное «не
# используется» роняет nginx -t уже после подмены бинарника.
#
# Работаем с ТОЧНЫМИ токенами, а не подстроками: "--with-mail" является
# префиксом "--with-mail_ssl_module", и подстрочное сравнение сняло бы не то.
# ---------------------------------------------------------------------------

# флаг % регулярка директив % dev-пакеты
#
# Разделитель полей — `%`, а не `;`: точка с запятой встречается внутри самих
# регулярок (граница директивы), и read резал бы их по первому же вхождению.
#
# Граница слева — начало строки, пробел, `;` или `{`, а не якорь `^[[:space:]]*`:
# директива сплошь и рядом стоит не первой в строке (`location /t/ { image_filter
# resize 150 100; }`), и якорь такую строку не видел бы. Проверено тестом: с
# якорем модуль вырезался при живой директиве — ошибка в самую опасную сторону.
#
# Справа границы нет намеренно. Из-за этого `upstream image_filter_backend`
# засчитается за использование модуля, и он останется вместе с libgd-dev. Это
# и есть выбранное направление ошибки: лишний пакет против упавшего nginx -t.
OPTIONAL_MODULES=(
    "--with-http_xslt_module%(^|[[:space:];{])(xslt_|xml_entities)%libxml2-dev libxslt1-dev"
    "--with-http_image_filter_module%(^|[[:space:];{])image_filter%libgd-dev"
    "--with-http_perl_module%(^|[[:space:];{])perl[_[:space:]]%libperl-dev"
    "--with-http_geoip_module%(^|[[:space:];{])geoip_%libgeoip-dev"
    "--with-stream_geoip_module%(^|[[:space:];{])geoip_%libgeoip-dev"
    "--with-mail%(^|[[:space:];{])mail[[:space:]]*\{%"
)

# Про stream_geoip отдельно. Ubuntu собирает geoip ДВАЖДЫ — как http-модуль и
# как stream-модуль, и оба динамические. Первая редакция таблицы знала только
# http-версию: сухой прогон на стенде показал --with-stream_geoip_module в
# итоговых флагах без libgeoip-dev, то есть ./configure упал бы так же, как на
# xslt, только на несколько минут позже. Директивы у stream-версии те же
# (geoip_country / geoip_city / geoip_org), поэтому регулярка общая: обе
# версии всегда вырезаются и остаются вместе, рассинхрона быть не может.
#
# Вырезать stream_geoip безопасно, несмотря на приставку stream: обязательны
# только --with-stream, --with-stream_ssl_module и --with-stream_ssl_preread_module,
# и они проверяются ниже отдельно. geoip к разбору SNI отношения не имеет.
#
# После этой строки таблица покрывает ВСЕ модули штатного nginx, которым нужны
# внешние библиотеки сборки: xslt (libxml2/libxslt), image_filter (libgd),
# perl (libperl), geoip обеих версий (libgeoip). Остальным хватает openssl,
# pcre2 и zlib, которые ставятся всегда.

# Сравнение через дополненную пробелами строку, а не `... | grep -qx`: grep -q
# выходит на первом совпадении, tr может получить SIGPIPE, и под pipefail
# найденный флаг вернул бы 141. Здесь же нет ни подпроцесса, ни этого класса.
has_arg() { [[ " $BUILD_ARGS " == *" $1 "* ]]; }

drop_arg() {
    local out
    out="$(tr ' ' '\n' <<< "$BUILD_ARGS" | grep -vxF -- "$1" | grep -v '^$' | tr '\n' ' ')" || true
    # Пустой результат означал бы, что фильтр съел вообще всё: молча
    # продолжать с пустыми флагами хуже, чем остановиться здесь.
    [[ -n "$out" ]] || die "внутренняя ошибка: после удаления ${1} не осталось ни одного флага сборки."
    BUILD_ARGS="$out"
}

EFFECTIVE_CONF="$(nginx -T 2>/dev/null || true)"
EXTRA_DEPS=""

if [[ -z "$EFFECTIVE_CONF" ]]; then
    # Безопасное вырождение: не зная конфига, не вырезаем ничего и платим
    # пятью dev-пакетами. Потерять модуль дороже.
    warn "nginx -T не отдал конфиг — ни одного модуля не вырезаю."
    warn "Ставлю зависимости сборки для всех необязательных модулей."
    for _entry in "${OPTIONAL_MODULES[@]}"; do
        IFS='%' read -r _flag _rx _pkgs <<< "$_entry"
        if has_arg "$_flag"; then
            EXTRA_DEPS+=" $_pkgs"
        fi
    done
else
    for _entry in "${OPTIONAL_MODULES[@]}"; do
        IFS='%' read -r _flag _rx _pkgs <<< "$_entry"
        if ! has_arg "$_flag"; then
            continue
        fi
        if grep -Eq -- "$_rx" <<< "$EFFECTIVE_CONF"; then
            log "  ${_flag}: директива найдена в конфиге — оставляю, доставлю ${_pkgs:-без зависимостей}"
            EXTRA_DEPS+=" $_pkgs"
        else
            log "  ${_flag}: в конфиге не используется — вырезаю"
            drop_arg "$_flag"
            # mail_ssl без mail — мусор в аргументах: снимаем парой.
            if [[ "$_flag" == "--with-mail" ]] && has_arg "--with-mail_ssl_module"; then
                drop_arg "--with-mail_ssl_module"
                log "  --with-mail_ssl_module: снят вместе с --with-mail"
            fi
        fi
    done
fi

# Схлопываем пробелы. EXTRA_DEPS накапливается с ведущим пробелом, а модуль без
# зависимостей сборки (mail) добавляет пустую строку — без нормализации даже
# «ничего не нужно» выглядело бы как непустое значение.
EXTRA_DEPS="$(tr -s ' ' <<< "$EXTRA_DEPS" | sed -e 's/^ //' -e 's/ $//')"

# ---------------------------------------------------------------------------
# Жёсткая проверка: stream обязан остаться.
#
# На нём держится разбор SNI на 443 (ssl_preread) — маршрутизация на панель и
# на REALITY, то есть вся маскировка. Ubuntu отдаёт его как --with-stream=dynamic,
# выше он превращается в статический. Если по любой причине он не доехал до
# итоговых флагов — прекращаем здесь, до первого изменения в системе.
# ---------------------------------------------------------------------------
for _req in --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module; do
    has_arg "$_req" || die "Во флагах сборки нет ${_req}. Без stream отвалится SNI-роутинг 443 (панель и REALITY) — сборка отменена, система не тронута."
done
log "stream на месте: SNI-роутинг 443 переживёт пересборку."

if [[ "$DRY_RUN" != "0" ]]; then
    echo
    log "СУХОЙ ПРОГОН (DRY_RUN=${DRY_RUN}) — система не тронута."
    echo
    echo "Итоговые флаги ./configure:"
    tr ' ' '\n' <<< "$BUILD_ARGS" | grep -v '^$' | sed 's/^/    /'
    echo
    echo "Дополнительные зависимости сборки: ${EXTRA_DEPS:-нет}"
    echo "cc-opt: ${CC_OPT:-нет}"
    echo "ld-opt: ${LD_OPT:-нет}"
    echo "OpenSSL ${OPENSSL_VER} → ${OPENSSL_PREFIX}"
    echo "nginx  ${NGINX_VER} → /usr/sbin/nginx (с бэкапом и откатом)"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. OpenSSL 3.5.x в изолированный префикс
# ---------------------------------------------------------------------------
log "Этап 1: сборка OpenSSL ${OPENSSL_VER} (долго)"

apt-get update -qq
# shellcheck disable=SC2086
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential zlib1g-dev perl libpcre2-dev wget $EXTRA_DEPS

cd /usr/local/src
if [[ ! -d "openssl-${OPENSSL_VER}" ]]; then
    wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" \
        || die "Не удалось скачать OpenSSL ${OPENSSL_VER}."
    tar xzf "openssl-${OPENSSL_VER}.tar.gz"
fi
cd "openssl-${OPENSSL_VER}"
# -Wl,-rpath обязателен. Без него бинарник в ${OPENSSL_PREFIX}/bin ищет
# libssl/libcrypto по стандартным путям и находит СИСТЕМНЫЕ 3.0.13, в которых
# нет символов версий 3.2-3.5. Проверено на стенде: собранный без rpath
# openssl падал с "version `OPENSSL_3.5.0' not found", а с LD_LIBRARY_PATH
# тот же бинарник печатал 3.5.6.
#
# Почему не LD_LIBRARY_PATH: _pq_openssl_bin в menu_telemt.sh вызывает
# бинарник голым, без окружения. Переменная в SUMMARY этого не изменила бы —
# PQ-часть пункта 5 просто молча не работала бы, то есть мы вернулись бы к
# тому же дефекту, ради которого добавлен make install_sw.
#
# Два пути: OpenSSL кладёт библиотеки в lib64 на x86_64 и в lib на других
# архитектурах. Лишний rpath на несуществующий каталог безвреден.
./Configure --prefix="$OPENSSL_PREFIX" --openssldir="${OPENSSL_PREFIX}/ssl" shared \
    "-Wl,-rpath,${OPENSSL_PREFIX}/lib64" "-Wl,-rpath,${OPENSSL_PREFIX}/lib"
make -j"$(nproc)"

# install_sw, а не install: последний тянет ещё и man-страницы, а нужен софт.
#
# ПОРЯДОК ВАЖЕН: установка обязана пройти ДО этапа 2. nginx с
# --with-openssl=<исходники> делает в этом же дереве `make clean` и
# пересобирает OpenSSL под себя (no-shared) — всё, что не установлено к тому
# моменту, будет уничтожено.
#
# Без этой установки ${OPENSSL_PREFIX} не появлялся вовсе. Итог был тихий:
# SUMMARY советовал PATH на несуществующий каталог, а _pq_openssl_bin в
# menu_telemt.sh искал ${OPENSSL_PREFIX}/bin/openssl — и PQ-часть пункта
# «Сверить TLS маски и панели» оставалась «Пропущено» даже после успешной
# пересборки, то есть проверить главное следствие работы было нечем.
make install_sw

# Проверяем фактом, а не кодом возврата make. Запускаем ГОЛЫМ, без
# LD_LIBRARY_PATH, — ровно так, как это делает _pq_openssl_bin в
# menu_telemt.sh. Именно эта проверка и поймала отсутствие rpath: make
# отработал успешно, файл лежал на месте и был исполняемым, а запуск падал
# на несовместимых системных библиотеках. По коду возврата make всё
# выглядело сделанным.
PQ_OPENSSL="${OPENSSL_PREFIX}/bin/openssl"
[[ -x "$PQ_OPENSSL" ]] || die "${PQ_OPENSSL} не появился после make install_sw."
PQ_VER="$("$PQ_OPENSSL" version 2>/dev/null | awk '{print $2}')" || PQ_VER=""
[[ "$PQ_VER" == "$OPENSSL_VER" ]] \
    || die "${PQ_OPENSSL} не запускается или показывает версию '${PQ_VER:-пусто}' вместо ${OPENSSL_VER}."

log "OpenSSL собран и установлен в ${OPENSSL_PREFIX} (${PQ_VER})."

# ---------------------------------------------------------------------------
# 2. nginx с --with-openssl=<исходники>
# ---------------------------------------------------------------------------
log "Этап 2: сборка nginx ${NGINX_VER}"

cd /usr/local/src
if [[ ! -d "nginx-${NGINX_VER}" ]]; then
    wget -q "http://nginx.org/download/nginx-${NGINX_VER}.tar.gz" \
        || die "Не удалось скачать исходники nginx ${NGINX_VER}."
    tar xzf "nginx-${NGINX_VER}.tar.gz"
fi
cd "nginx-${NGINX_VER}"

# shellcheck disable=SC2086
eval ./configure $BUILD_ARGS \
    ${CC_OPT:+--with-cc-opt="'$CC_OPT'"} \
    ${LD_OPT:+--with-ld-opt="'$LD_OPT'"} \
    --with-openssl="/usr/local/src/openssl-${OPENSSL_VER}"

make -j"$(nproc)"
log "nginx собран."

# Снимок в переменную, а не конвейер в grep -q. Под pipefail grep -q выходит
# на первом совпадении, а `nginx -V` печатает следом длинную строку флагов —
# producer получил бы SIGPIPE, конвейер вернул бы 141, и die сработал бы на
# успешной сборке. На стенде не выстрелило (вывод целиком помещается в буфер
# трубы), но это ровно та ловушка, что уже дважды находилась в этом файле.
NEW_NGINX_V="$(./objs/nginx -V 2>&1)" || NEW_NGINX_V=""
grep -q "OpenSSL ${OPENSSL_VER}" <<< "$NEW_NGINX_V" \
    || die "Собранный бинарник не показывает OpenSSL ${OPENSSL_VER} — установка отменена, система не тронута."

# ---------------------------------------------------------------------------
# 3. Подмена бинарника с откатом
# ---------------------------------------------------------------------------
log "Этап 3: установка нового бинарника"

BACKUP=/usr/sbin/nginx.pre-openssl35.bak
MODS_BACKUP=/etc/nginx/modules-enabled.pre-openssl35.bak
CONF_BACKUP=/etc/nginx/nginx.conf.pre-openssl35.bak

# ---------------------------------------------------------------------------
# Парный подъём стека (инвариант 2).
#
# У telemt.service стоит Requires=nginx.service, поэтому `systemctl stop nginx`
# ниже уносит и telemt, и telemt-panel. Прежняя версия поднимала только nginx:
# после 20-40 минут сборки печаталось зелёное «Готово», а прокси лежал, и
# единственным намёком была строка `telemt: [ОСТАНОВЛЕН]` в шапке меню под
# самим рапортом. Остановка по пропагации сама не восстанавливается.
#
# Запоминаем ДО остановки: после неё is-active скажет inactive про обе службы,
# и отличить «мы их уронили» от «их тут и не было» станет нечем.
# ---------------------------------------------------------------------------
STOPPED_SERVICES=""
for _svc in telemt telemt-panel; do
    if systemctl is-active --quiet "$_svc" 2>/dev/null; then
        STOPPED_SERVICES="$STOPPED_SERVICES $_svc"
    fi
done

RESTORE_FAILED=0
RESTORED_SERVICES=""

restore_stack_services() {
    [[ -n "$STOPPED_SERVICES" ]] || return 0
    local svc
    # Список нужен итоговой рамке уже после того, как STOPPED_SERVICES
    # очищен: очистка защищает от повторного подъёма, если функция вызвана
    # дважды (успешная ветка и trap), а печатать всё равно есть что.
    RESTORED_SERVICES="$STOPPED_SERVICES"
    echo
    log "Возвращаю остановленные службы:${STOPPED_SERVICES}"
    # shellcheck disable=SC2086
    for svc in $STOPPED_SERVICES; do
        systemctl start "$svc" || true
    done
    # Проверяем фактом. Для Type=simple `systemctl start` возвращает 0 сразу
    # после форка и о работоспособности службы не говорит ничего, а telemt
    # ждёт nginx — отсюда wait_until, а не голая проверка следом за стартом.
    # Пауза перед перепроверкой — не критерий, а окно наблюдения. Служба,
    # которая стартует и тут же падает, в первую секунду неотличима от
    # здоровой: systemd успевает отдать active, а Restart= ещё не сработал.
    # Ревью проекта отдельно отмечает этот дефект: служба в цикле перезапуска
    # показывается как РАБОТАЕТ, потому что смотрят на is-active без NRestarts.
    sleep 3
    # shellcheck disable=SC2086
    for svc in $STOPPED_SERVICES; do
        local nr
        if ! wait_until 10 systemctl is-active --quiet "$svc"; then
            warn "    ${svc} НЕ поднялся — смотри journalctl -u ${svc} -n 50"
            RESTORE_FAILED=1
            continue
        fi
        nr="$(systemctl show -p NRestarts --value "$svc" 2>/dev/null)" || nr=0
        if [[ "${nr:-0}" -gt 0 ]]; then
            warn "    ${svc} active, но перезапускался ${nr} раз — смотри journalctl -u ${svc} -n 50"
            RESTORE_FAILED=1
        else
            log "    ${svc} работает"
        fi
    done
    STOPPED_SERVICES=""
}

# Между остановкой nginx и подъёмом служб прерывание или обрыв связи не должны
# оставить сервер без прокси. Тот же приём, что вокруг certbot в menu_setup.sh.
trap 'echo; warn "Прервано — восстанавливаю службы."; restore_stack_services; exit 130' INT TERM HUP

# Бэкап бинарника НЕ перезаписываем, если он уже есть.
#
# При повторном запуске (вышла новая версия nginx, обновился OpenSSL) `cp`
# положил бы в бэкап уже пересобранный статический бинарник. Откат после
# этого стал бы ломающим: modules-enabled.pre-openssl35.bak при этом
# сохраняется с первого запуска — блок ниже пропускается, когда каталог уже
# пуст, — и откат вернул бы статический бинарник ВМЕСТЕ с директивами
# load_module. Это ровно то, от чего предостерегает комментарий ниже:
# "module already loaded", nginx не стартует, а по инварианту 2 за ним
# ложится telemt.
#
# Плюс довод попроще: пакетный бинарник — единственное состояние, которое
# нельзя получить обратно одной командой (пакеты захолжены). Пересобранный
# воспроизводится повторным запуском этого же скрипта.
if [[ -f "$BACKUP" ]]; then
    log "  бэкап бинарника уже есть, прежний сохраняю: $BACKUP"
else
    cp /usr/sbin/nginx "$BACKUP"
fi

# А вот конфиг перезаписываем каждый раз, и это намеренно. Он нужен только
# для отката ВНУТРИ текущего запуска: снимается прямо перед sed, который
# удаляет строку load_module, и восстанавливается тут же при провале. Хранить
# старую копию было бы хуже — откат затёр бы правки, сделанные в конфиге за
# время между запусками.
cp /etc/nginx/nginx.conf "$CONF_BACKUP"
systemctl stop nginx
cp ./objs/nginx /usr/sbin/nginx

# ---------------------------------------------------------------------------
# Приведение modules-enabled в согласие с новым бинарником.
#
# Прежняя версия вычищала каталог ЦЕЛИКОМ. На стенде там лежало восемь файлов,
# и семь из них — сторонние модули из nginx-extras: echo, subs_filter, geoip2
# (http и stream), auth_pam, dav_ext, upstream_fair. В `nginx -V` их нет вовсе:
# Debian собирает их отдельными пакетами против ABI nginx, а не флагами
# configure. Пересборка убивала их молча — ровно то, от чего предостерегает
# комментарий в начале файла, где сказано, что модули берутся из реальной
# установки, чтобы «geoip2, nginx-extras... не потерялись».
#
# Терять их не нужно: `--with-compat` сохраняется в флагах, и проверено на
# стенде — все семь загружаются в пересобранный nginx без единой жалобы.
# Конфликтует только тот модуль, который мы САМИ встроили статически: nginx
# отвергает его с «module ... is already loaded».
#
# Поэтому снимаем ровно конфликтующие, и находим их ПО ФАКТУ — по жалобе
# nginx -t, а не по имени файла. Набор =dynamic зависит от дистрибутива и
# версии, список имён разошёлся бы с реальностью при первом же обновлении.
# ---------------------------------------------------------------------------
if [[ -d /etc/nginx/modules-enabled ]] && compgen -G "/etc/nginx/modules-enabled/*" >/dev/null; then
    if [[ -d "$MODS_BACKUP" ]]; then
        # Не перезаписываем по той же причине, что и бэкап бинарника: он
        # обязан описывать состояние ДО первой пересборки, иначе откат
        # вернёт пакетный бинарник с уже подрезанным набором модулей.
        log "  бэкап modules-enabled уже есть, прежний сохраняю"
    else
        cp -a /etc/nginx/modules-enabled "$MODS_BACKUP"
        log "  бэкап modules-enabled: $MODS_BACKUP"
    fi
fi

# Строка load_module в самом nginx.conf — отдельный путь подключения, его
# использует не Ubuntu, а сторонние установщики. Обрабатываем так же.
sed -i '/^\s*load_module.*ngx_stream_module\.so;/d' /etc/nginx/nginx.conf

prune_conflicting_modules() {
    local i out mod file
    for i in $(seq 10); do
        if out="$(nginx -t 2>&1)"; then
            return 0
        fi
        # Без `| head -1`: под pipefail head выходит после первой строки,
        # grep получает SIGPIPE, конвейер возвращает 141 — и `|| mod=""`
        # затирает УСПЕШНО найденное имя. Первую строку берём разворачиванием
        # параметра, конвейера тут нет вовсе.
        mod="$(grep -oP 'module "\K[^"]+(?=" is already loaded)' <<< "$out")" || mod=""
        mod="${mod%%$'\n'*}"
        # Жалоба не про повторную загрузку — это уже не наш случай, пусть
        # разбирается проверка nginx -t ниже и, если надо, откат.
        [[ -n "$mod" ]] || return 1
        # Перечисляем файлы глобом, а НЕ через grep -r по каталогу: в Ubuntu
        # /etc/nginx/modules-enabled/ состоит из симлинков на
        # /usr/share/nginx/modules-available/, а рекурсивный grep по симлинкам
        # не ходит. С -r имя модуля разбиралось верно, файл не находился, и
        # функция сдавалась, не сняв ничего, — поймано прогоном на стенде.
        # Симлинк, названный в аргументах, grep разыменовывает, и возвращает
        # путь именно в modules-enabled — тот, который и надо удалить.
        file="$(grep -ls "${mod}\.so" /etc/nginx/modules-enabled/* 2>/dev/null)" || file=""
        file="${file%%$'\n'*}"
        [[ -n "$file" ]] || return 1
        rm -f "$file"
        log "  снят $(basename "$file"): ${mod} теперь встроен статически"
    done
    return 1
}

if prune_conflicting_modules; then
    kept="$(ls -A /etc/nginx/modules-enabled/ 2>/dev/null | wc -l)"
    log "  сторонних модулей сохранено: ${kept}"
else
    warn "  modules-enabled согласовать не удалось — решит проверка nginx -t ниже"
fi

rollback() {
    warn "Откатываюсь на прежний бинарник..."
    cp "$BACKUP" /usr/sbin/nginx
    if [[ -d "$MODS_BACKUP" ]]; then
        cp -a "$MODS_BACKUP"/. /etc/nginx/modules-enabled/ 2>/dev/null || true
    fi
    # Возвращаем и nginx.conf. Строку load_module ngx_stream_module.so выше
    # снимает sed, а прежнему — динамическому — бинарнику она необходима:
    # без неё откат оставил бы сервер без stream, то есть без разбора SNI на
    # 443. Бэкап бинарника без бэкапа конфига чинил только половину.
    if [[ -f "$CONF_BACKUP" ]]; then
        cp "$CONF_BACKUP" /etc/nginx/nginx.conf
    fi
    if nginx -t >/dev/null 2>&1; then
        if systemctl start nginx; then
            log "nginx поднят на прежней версии."
        else
            warn "nginx не стартовал даже после отката!"
        fi
    else
        systemctl start nginx 2>/dev/null || true
        warn "nginx -t не проходит даже после отката — проверь конфиг вручную!"
    fi
    restore_stack_services
}

if ! nginx -t; then
    rollback
    die "nginx -t упал после подмены бинарника. Откат выполнен, сервис работает на старом nginx."
fi

if ! systemctl start nginx; then
    rollback
    die "nginx не стартовал с новым бинарником. Откат выполнен."
fi

restore_stack_services
trap - INT TERM HUP

systemctl status nginx --no-pager || true
apt-mark hold nginx nginx-common nginx-full >/dev/null 2>&1 || true

log "Готово:"
nginx -V 2>&1 | grep "OpenSSL"

# Итог печатаем ПО ФАКТУ. Зелёная рамка поверх лежащего telemt — ровно тот
# класс дефекта, из-за которого этот блок и переписан.
if [[ "$RESTORE_FAILED" -ne 0 ]]; then
    cat << FAILED_SUMMARY

════════════════════════════════════════════════════════════════
nginx пересобран с OpenSSL ${OPENSSL_VER}, НО СТЕК ПОДНЯЛСЯ НЕ ПОЛНОСТЬЮ.

Проверь и подними вручную:
  systemctl status telemt telemt-panel
  journalctl -u telemt -n 50

Пока служба лежит, прокси не работает — клиенты отваливаются молча.
════════════════════════════════════════════════════════════════
FAILED_SUMMARY
    exit 1
fi

# Перечисляем только те бэкапы, которые действительно созданы: modules-enabled
# сохраняется не всегда (каталога может не быть или он пуст), а рамка, обещающая
# несуществующий файл, — тот же рапорт поверх факта, только помельче.
BACKUPS_LINE="Бэкап бинарника: ${BACKUP}"
if [[ -d "$MODS_BACKUP" ]]; then
    BACKUPS_LINE="${BACKUPS_LINE}
Бэкап modules-enabled: ${MODS_BACKUP}"
fi
if [[ -f "$CONF_BACKUP" ]]; then
    BACKUPS_LINE="${BACKUPS_LINE}
Бэкап nginx.conf: ${CONF_BACKUP}"
fi

cat << SUMMARY

════════════════════════════════════════════════════════════════
nginx пересобран с OpenSSL ${OPENSSL_VER}, пакеты захолжены (apt-mark hold).
Стек поднят: nginx${RESTORED_SERVICES}

${BACKUPS_LINE}

ВАЖНО: пакет захолжен — security-обновления nginx больше не приедут
автоматически. При выходе новой версии повтори пересборку вручную.

Побочно: пока фиксация стоит, apt отказывается удалять nginx — а это делает
пункт «Удалить панель X-UI». Он снимает её сам, вручную ничего не нужно.

Проверка PQ — пункт 5 меню telemt «Сверить TLS маски и панели»: он сам
находит ${PQ_OPENSSL} и требует, чтобы PQ был согласован на ОБОИХ портах.
Вручную:
  ${PQ_OPENSSL} s_client -connect <IP>:<порт telemt> -groups X25519MLKEM768
════════════════════════════════════════════════════════════════
SUMMARY
