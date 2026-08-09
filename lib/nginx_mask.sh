#!/bin/bash

# ======================================================================
# ОБЩИЙ ГЕНЕРАТОР self-SNI VHOST ДЛЯ TELEMT
#
# Сорсится двумя потребителями: stacks/telemt.sh (standalone-установщик,
# set -euo pipefail, свои log/warn/die) и menus/telemt.sh (интерактивное меню
# с цветами). Поэтому здесь нет ни цветов, ни read, ни exit, а ветвления
# записаны так, чтобы пережить set -e и set -u у вызывающего: голое
# "[ -n "$x" ] && cmd" под set -e роняет скрипт, когда условие ложно, —
# везде полная форма if/fi.
#
# Раньше vhost собирался двумя копиями одного heredoc, и копии несли
# одинаковый дефект: обе писали "http2 on;" — директиву nginx >= 1.25.1,
# тогда как 3x-ui-pro ставит nginx из репозитория дистрибутива (Ubuntu 24.04
# — 1.24.0, Debian 12 — 1.22.1), где её нет. Один генератор на обоих, чтобы
# следующая правка не чинилась в одном файле и забывалась в другом.
# ======================================================================

# vhost лежит в conf.d, а НЕ в sites-enabled: установщик и патч 3x-ui-pro
# очищают sites-enabled целиком (rm -rf / find -delete), и файл там молча
# исчезал бы вместе с маскировкой.
MASK_VHOST="/etc/nginx/conf.d/telemt-mask.conf"

# ----------------------------------------------------------------------
# Путь к vhost панели. Печатает найденный путь в stdout.
# ----------------------------------------------------------------------
nginx_mask_panel_vhost() {
    local domain="$1" candidate
    for candidate in "/etc/nginx/sites-available/$domain" \
                     "/etc/nginx/sites-enabled/$domain"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo "не найден vhost домена $domain — панель 3x-ui-pro установлена именно на этот домен?" >&2
    return 1
}

# ----------------------------------------------------------------------
# Извлекает из vhost панели webroot и пути к сертификату в переменные
# MASK_WEBROOT / MASK_CERT / MASK_KEY.
#
# Значения берём из живого vhost, а не из своих дефолтов: маска обязана
# отдавать ровно тот же сертификат и тот же webroot, что и панель, — иначе
# пробер отличает порт telemt от сайта по цепочке сертификатов.
#
# "|| true" на каждом присваивании обязателен: у stacks/telemt.sh включён
# pipefail, и пустой grep вернул бы 1 через head, а set -e убил бы скрипт
# ДО проверки ниже — вместо внятной ошибки пользователь получал молчаливый
# выход с пустым выводом.
# ----------------------------------------------------------------------
# Текст TLS-блока панели: комментарии убраны, взят ТОЛЬКО тот server{}, где
# есть ssl_certificate.
#
# Раньше значения искались по всему файлу через head -1, и в типовом vhost вида
# «80 → редирект на 443» первым сверху лежит блок порта 80 со своим
# root /var/www/acme. Маска получала ACME-каталог вместо корня сайта, то есть
# отдавала не то содержимое, что панель, — при формально исправной проверке
# «отвечает 200». Поймано собственным тестом на certbot-подобном конфиге.
nginx_mask_tls_block() {
    local vhost="$1"
    grep -vE '^[[:space:]]*#' "$vhost" 2>/dev/null | awk '
        /^[[:space:]]*server[[:space:]]*\{/ && depth==0 { depth=1; buf=$0 "\n"; found=0; next }
        depth>0 {
            buf = buf $0 "\n"
            if ($0 ~ /ssl_certificate[[:space:]]/) found=1
            depth += gsub(/\{/,"{")
            depth -= gsub(/\}/,"}")
            if (depth<=0) { if (found) { printf "%s", buf; exit } ; buf=""; depth=0 }
        }
    ' || true
}

nginx_mask_scrape() {
    local vhost="$1" block
    block="$(nginx_mask_tls_block "$vhost")"
    # Запасной путь: если server{} с сертификатом не нашёлся (нестандартное
    # оформление, вложенный include), разбираем файл целиком без комментариев —
    # прежнее поведение, но хотя бы без закомментированных строк.
    if [ -z "$block" ]; then
        block="$(grep -vE '^[[:space:]]*#' "$vhost" 2>/dev/null || true)"
    fi

    MASK_WEBROOT="$(printf '%s\n' "$block" | grep -oP '^\s*root\s+\K[^;]+' | head -1 || true)"
    MASK_CERT="$(printf '%s\n' "$block" | grep -oP '^\s*ssl_certificate\s+\K[^;]+' | head -1 || true)"
    MASK_KEY="$(printf '%s\n' "$block" | grep -oP '^\s*ssl_certificate_key\s+\K[^;]+' | head -1 || true)"

    if [ -z "$MASK_WEBROOT" ] || [ -z "$MASK_CERT" ] || [ -z "$MASK_KEY" ]; then
        echo "не удалось извлечь root/ssl_certificate/ssl_certificate_key из $vhost" >&2
        return 1
    fi

    MASK_TLS="$(printf '%s\n' "$block" | nginx_mask_scrape_tls)"
    return 0
}

# ----------------------------------------------------------------------
# TLS-директивы панели, которые маска обязана повторить дословно.
#
# Раньше здесь стояли захардкоженные ssl_protocols и ssl_ciphers. Это ломало
# ровно то, ради чего написан весь файл: директива в server-блоке ПЕРЕКРЫВАЕТ
# унаследованное из http{}, поэтому на маске становился эффективным наш широкий
# набор (HIGH:...), а на 443 — узкий список панели. Активному проберу хватало
# одного соединения: ClientHello с TLS 1.2 и только не-PFS суитами маска
# принимала, а панель отвечала handshake_failure. Такого расхождения у одного
# сайта на одном сервере быть не может — это готовая сигнатура.
#
# Правило простое: в маске присутствует ровно то, что присутствует у панели, и
# ничего больше. Директиву, которую панель не задаёт, мы не пишем тоже — оба
# server-блока живут в одном nginx и унаследуют из http{} одно и то же.
#
# include копируем только «ssl-шный» (типовой vhost под certbot подключает
# options-ssl-nginx.conf, где и лежат настоящие протоколы и шифры). Копировать
# include без разбора нельзя: туда затянет location-блоки панели.
# ----------------------------------------------------------------------
# Читает текст блока со стандартного ввода, печатает готовые строки для vhost.
nginx_mask_scrape_tls() {
    local line out=""
    local keys='ssl_protocols|ssl_ciphers|ssl_prefer_server_ciphers|ssl_ecdh_curve'
    keys="$keys|ssl_conf_command|ssl_session_cache|ssl_session_timeout|ssl_session_tickets"
    keys="$keys|ssl_stapling|ssl_stapling_verify|ssl_trusted_certificate|ssl_early_data"
    keys="$keys|ssl_buffer_size|ssl_dhparam"

    while IFS= read -r line; do
        case "$line" in '#'*|'') continue ;; esac
        if [[ "$line" =~ ^($keys)[[:space:]] ]] || [[ "$line" =~ ^include[[:space:]]+[^\;]*ssl[^\;]*\; ]]; then
            out="${out}    ${line}"$'\n'
        fi
    done < <(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    printf '%s' "$out"
}

# ----------------------------------------------------------------------
# Нужен ли HTTP/2 в маске. Зеркалим ФАКТ из vhost панели, а не свои
# предпочтения: маска и панель обязаны совпадать по ALPN, иначе активный
# пробер отличает порт telemt от настоящего сайта за один хэндшейк.
# ----------------------------------------------------------------------
nginx_mask_http2_wanted() {
    local panel_vhost="$1"

    # Без вкомпилированного модуля не сработает НИ ОДНА форма записи.
    # Проверяем именно nginx -V, а не версию: stacks/nginx-openssl35.sh
    # подменяет /usr/sbin/nginx своей сборкой, сохраняя номер версии, и
    # набор модулей у неё может отличаться от дистрибутивного.
    nginx -V 2>&1 | grep -q -- '--with-http_v2_module' || return 1

    # Две формы: "listen ... http2" (nginx < 1.25.1) и "http2 on;" (>= 1.25.1).
    # Закомментированные строки не в счёт. Директивы вроде
    # http2_body_preread_size под шаблон не попадают — за "http2" обязан идти
    # пробел или точка с запятой.
    grep -vE '^[[:space:]]*#' "$panel_vhost" 2>/dev/null | grep -qE \
        '^[[:space:]]*listen[[:space:]]+[^;]*[[:space:]]http2([[:space:]]|;)|^[[:space:]]*http2[[:space:]]+on[[:space:]]*;'
}

# ----------------------------------------------------------------------
# Текст vhost в stdout.
# ----------------------------------------------------------------------
nginx_mask_render() {
    local port="$1" domain="$2" webroot="$3" cert="$4" key="$5" http2_flag="$6" tls="$7"

    cat << EOF
# self-SNI цель для telemt. Файл создан VSM, правки затрутся при следующем
# запуске установщика или пункта "Восстановить маскировку".
#
# Лежит в conf.d намеренно: установщик и патч 3x-ui-pro очищают
# sites-enabled целиком, и здесь файл это переживает.
#
# БЕЗ proxy_protocol: telemt при сплайсинге заголовок не добавляет,
# поэтому направить маскировку на штатный 7443 нельзя.
#
# HTTP/2 включается СТАРОЙ формой (listen ... http2). Она валидна и на
# nginx < 1.25.1, и на новых версиях — там лишь предупреждение об
# устаревании. Новая форма "http2 on;" появилась только в 1.25.1 и роняет
# nginx -t на дистрибутивных 1.18/1.22/1.24. Переходить на "http2 on;"
# имеет смысл только когда старая форма будет удалена из nginx.
server {
    listen 127.0.0.1:${port} ssl${http2_flag};

    server_name ${domain};
    root ${webroot};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
${tls}
    # index.php убран: обработчика PHP в маске нет, и при появлении в webroot
    # любого .php панель на 443 отдала бы отрендеренную страницу, а маска — тот
    # же файл ИСХОДНИКОМ. Это и раскрытие, и различитель портов за один запрос.
    # Если в webroot панели когда-нибудь появится PHP, сюда нужно переносить и
    # location ~ \.php$ с тем же fastcgi_pass, что у панели.
    index index.html index.htm;
}
EOF
}

# ----------------------------------------------------------------------
# Записывает vhost, проверяет конфиг и перезагружает nginx.
# При провале ОТКАТЫВАЕТ: битый файл в conf.d не даёт nginx стартовать
# вообще, поэтому оставлять его нельзя — следующий reboot, systemctl restart
# или renew-hook certbot уронит вместе с ним и панель. Ровно так и вышло
# в бою: файл с "http2 on;" пролежал ночь, и утренний рестарт не поднял
# nginx.
#
# 0 — установлено и nginx перезагружен; 1 — не применено, причина в stderr.
# ----------------------------------------------------------------------
nginx_mask_install() {
    local content="$1"
    local backup="${MASK_VHOST}.bak"
    local had_previous=0

    mkdir -p "$(dirname "$MASK_VHOST")" || return 1

    # Прежний файл отодвигаем переименованием в тот же каталог, а не копией во
    # временный: mv в пределах одной ФС атомарен и не зависит от свободного
    # места в /tmp, тогда как незамеченный провал cp оставил бы нас с пустым
    # "бэкапом" и молча стёр рабочую маску при откате. Суффикс .bak не подходит
    # под include *.conf, поэтому nginx этот файл не читает.
    if [ -f "$MASK_VHOST" ]; then
        if ! mv -f "$MASK_VHOST" "$backup"; then
            echo "не удалось отложить прежний $MASK_VHOST — операция отменена, конфиг не тронут" >&2
            return 1
        fi
        had_previous=1
    fi

    if ! printf '%s\n' "$content" > "$MASK_VHOST"; then
        echo "не удалось записать $MASK_VHOST" >&2
        if [ "$had_previous" = 1 ]; then
            mv -f "$backup" "$MASK_VHOST"
        fi
        return 1
    fi

    if nginx -t; then
        rm -f "$backup"
        # Код reload проверяем явно: вызывающий обращается к нам в контексте
        # "|| die", а там errexit внутри функции не действует, и молчаливый
        # провал reload выдал бы себя только отсутствием маскировки.
        if ! systemctl reload nginx; then
            echo "конфиг принят nginx -t и оставлен на месте, но systemctl reload nginx не сработал — маскировка заработает только после успешного старта nginx" >&2
            return 1
        fi
        return 0
    fi

    if [ "$had_previous" = 1 ]; then
        mv -f "$backup" "$MASK_VHOST"
    else
        rm -f "$MASK_VHOST"
    fi

    # Подтверждаем, что откат вернул конфиг в валидное состояние: если nginx -t
    # не проходит и после отката, ошибка была не в нашем файле, и сообщать
    # надо другое.
    if nginx -t >/dev/null 2>&1; then
        echo "конфиг маскировки отклонён nginx -t, изменения откачены" >&2
    else
        echo "nginx -t не проходит и ПОСЛЕ отката — ошибка не в файле маскировки, разбирай вывод nginx -t вручную" >&2
    fi
    return 1
}

# ----------------------------------------------------------------------
# Полный цикл: найти vhost панели, снять с него параметры, собрать маску
# и установить её с откатом при неудаче. Единственная точка входа для
# обоих потребителей.
# ----------------------------------------------------------------------
nginx_mask_apply() {
    local domain="$1" port="$2"
    local panel_vhost http2_flag=""

    # Пустой порт приезжает из старого /etc/vsm/telemt.conf, где ключа
    # TELEMT_MASK_PORT ещё не было. Без проверки получился бы "listen
    # 127.0.0.1: ssl" — валидный по виду мусор, который ловится только
    # на nginx -t.
    if [ -z "$domain" ] || ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        echo "нужны непустой домен панели и числовой порт маскировки (домен='$domain', порт='$port')" >&2
        return 1
    fi

    panel_vhost="$(nginx_mask_panel_vhost "$domain")" || return 1
    nginx_mask_scrape "$panel_vhost" || return 1

    if nginx_mask_http2_wanted "$panel_vhost"; then
        http2_flag=" http2"
    fi

    nginx_mask_install "$(nginx_mask_render \
        "$port" "$domain" "$MASK_WEBROOT" "$MASK_CERT" "$MASK_KEY" "$http2_flag" "$MASK_TLS")"
}
