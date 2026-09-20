#!/bin/bash

# ======================================================================
# АВТОПРОДЛЕНИЕ СЕРТИФИКАТА
#
# ЗАЧЕМ. Сертификат Let's Encrypt живёт 90 дней. Пока он действует, всё
# выглядит исправным; в день истечения разом отваливается ВСЁ, что стоит за
# nginx: панель 3x-ui на 443, маскировка telemt на 8444, веб-панель за
# секретным путём. Причём отваливается хуже, чем просто «не открывается»:
# маскировочный сайт начинает отдавать просроченный сертификат, то есть
# ровно ту примету, которую вся установка и прячет.
#
# ЧТО БЫЛО СЛОМАНО. VSM выпускает сертификат способом standalone: certbot
# сам поднимает сервер на порту 80, для чего пункт меню гасит nginx и потом
# возвращает. Выпуск при этом проходит — а вот продление НЕТ. Способ
# запоминается в /etc/letsencrypt/renewal/<домен>.conf, при автоматическом
# продлении по certbot.timer nginx никто не останавливает, порт 80 занят им
# же, и продление падает. Замерено на стенде 20.09.2026:
#
#   certbot renew --dry-run
#   Failed to renew certificate adkrw.kagis.kz with error: Could not bind TCP
#   port 80 because it is already in use by another process on this system
#
# Тишина полная: таймер отработал, в журнале ошибка, никто не смотрит.
#
# ЧТО ДЕЛАЕМ. Переводим продление на webroot: certbot кладёт файл-ответ в
# каталог сайта, а отдаёт его работающий nginx. Порт 80 освобождать не надо,
# простоя нет вовсе — замерено репетицией при работающем стеке: панель, 8444
# и веб-панель отвечали 200 всё время продления.
#
# Нужны три вещи, и все три проверяются позицией реестра cert_renew:
#
#   1. Путь /.well-known/acme-challenge/ отдаётся по http на порту 80.
#   2. В renewal-файлах способ webroot, а не standalone.
#   3. Хук, перезагружающий nginx после продления, — иначе nginx продолжит
#      держать в памяти СТАРЫЙ сертификат до ближайшего перезапуска, то есть
#      просроченный.
#
# ПОЧЕМУ ПОЗИЦИЯ КЛАССА fix, хотя правит чужой vhost. Соседняя позиция
# web_nginx_block намеренно класса tell: там врезка меняет то, что видно
# снаружи. Здесь не меняет ничего — путь проверки при пустом каталоге отдаёт
# 404 ровно как и прежде, а цена бездействия это одновременная остановка
# всего стека через месяц-другой, о которой некому вспомнить.
# ======================================================================

CERT_RENEWAL_DIR="${CERT_RENEWAL_DIR:-/etc/letsencrypt/renewal}"
CERT_HOOK_DIR="${CERT_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
CERT_HOOK_FILE="${CERT_HOOK_FILE:-$CERT_HOOK_DIR/00-vsm-reload-nginx.sh}"
# Каталог сайта, он же корень маскировки 3x-ui-pro. Тот же, что отдаёт nginx
# на 80 и 443: файл-ответ должен лежать там, куда придёт Let's Encrypt.
CERT_ACME_ROOT="${CERT_ACME_ROOT:-/var/www/html}"
CERT_ACME_BEGIN="# >>> VSM acme-challenge"
CERT_ACME_END="# <<< VSM acme-challenge"
# Копии правленых чужих файлов. 700 — тот же каталог, где лежат копии vhost с
# секретными префиксами панелей.
CERT_BACKUP_DIR="${CERT_BACKUP_DIR:-/var/backups/vsm/nginx}"
CERT_NGINX_DIRS="${CERT_NGINX_DIRS:-/etc/nginx/sites-enabled /etc/nginx/conf.d}"

# ----------------------------------------------------------------------
# Файл, где описан сервер на порту 80.
#
# Требование «ровно один» намеренное и такое же, как у panel_domain: на
# установке с чужим default-конфигом кандидатов два, и врезать путь проверки
# не в тот означает молча оставить продление сломанным. Лучше сказать, что не
# разобрались, чем уверенно сделать не то.
# ----------------------------------------------------------------------
cert_acme_vhost() {
    local d f real found="" hits=0
    for d in $CERT_NGINX_DIRS; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            real="$(readlink -f "$f" 2>/dev/null)"
            [ -f "$real" ] || continue
            grep -qE '^[[:space:]]*listen[[:space:]]+(\[::\]:)?80[[:space:];]' "$real" 2>/dev/null || continue
            found="$real"
            hits=$((hits + 1))
        done
    done
    [ "$hits" -eq 1 ] || return 1
    printf '%s\n' "$found"
}

# ----------------------------------------------------------------------
# Врезает путь проверки в конфиг, прочитанный со стандартного входа.
#
# ДВЕ ТОНКОСТИ, обе стоили отдельного замера.
#
# Первая: перенаправление на https, стоящее на уровне server, выполняется
# РАНЬШЕ, чем nginx выбирает location, и перехватывает в том числе наш путь.
# Замерено 20.09.2026: с виду верный конфиг отдавал Let's Encrypt 301 вместо
# файла. Поэтому такое перенаправление переносится внутрь location /.
#
# Вторая: скобки считаются по строке БЕЗ комментария — иначе «# }» в чужом
# конфиге сдвинул бы границы блока, и врезка ушла бы не туда.
# ----------------------------------------------------------------------
cert_acme_insert() {
    awk -v begin="$CERT_ACME_BEGIN" -v end="$CERT_ACME_END" -v root="$CERT_ACME_ROOT" '
    function emit_acme() {
        print "    " begin
        print "    # Проверка владения доменом при продлении сертификата."
        print "    # Let'"'"'s Encrypt ходит сюда по http; пустой каталог отдаёт 404."
        print "    location ^~ /.well-known/acme-challenge/ {"
        print "        root " root ";"
        print "        default_type \"text/plain\";"
        print "        try_files $uri =404;"
        print "    }"
        print "    " end
    }
    { line[NR] = $0; if (index($0, begin)) already = 1 }
    END {
        # Уже врезано — отдаём как есть. Повторный проход добавил бы второй
        # такой же location, и nginx отказался бы собирать конфиг целиком.
        if (already) { for (i = 1; i <= NR; i++) print line[i]; exit 0 }

        depth = 0; start = 0; has80 = 0; ts = 0; te = 0
        for (i = 1; i <= NR; i++) {
            s = line[i]
            sub(/#.*$/, "", s)
            if (depth == 0 && s ~ /(^|[[:space:]])server[[:space:]]*\{/) { start = i; has80 = 0 }
            if (start && s ~ /listen[[:space:]]+(\[::\]:)?80[[:space:];]/) has80 = 1
            opened = gsub(/\{/, "{", s)
            closed = gsub(/\}/, "}", s)
            depth += opened - closed
            if (start && depth == 0) {
                if (has80 && !ts) { ts = start; te = i }
                start = 0
            }
        }
        if (!ts) { for (i = 1; i <= NR; i++) print line[i]; exit 1 }

        inserted = 0; d = 0
        for (i = 1; i <= NR; i++) {
            if (i < ts || i > te) { print line[i]; continue }

            s = line[i]
            sub(/#.*$/, "", s)
            opened = gsub(/\{/, "{", s)
            closed = gsub(/\}/, "}", s)

            # Перенаправление на уровне server (глубина 1) — внутрь location /.
            if (d == 1 && opened == 0 && line[i] ~ /^[[:space:]]*return[[:space:]]+30[0-9][[:space:]]/) {
                if (!inserted) { emit_acme(); inserted = 1 }
                print "    # Перенаправление стоит ЗДЕСЬ, а не на уровне server: там оно"
                print "    # выполняется до выбора location и перехватывает в том числе"
                print "    # проверку владения доменом — замерено 20.09.2026."
                print "    location / {"
                print "    " line[i]
                print "    }"
                d += opened - closed
                continue
            }

            print line[i]
            d += opened - closed

            if (!inserted && d == 1 && line[i] ~ /^[[:space:]]*server_name[[:space:]]/) {
                emit_acme(); inserted = 1
            }
            # Нет server_name вовсе — врезаем сразу после открытия блока.
            if (!inserted && i == ts && d == 1) { emit_acme(); inserted = 1 }
        }
    }'
}

# Есть ли путь проверки в конфиге порта 80.
cert_acme_present() {
    local vhost
    vhost="$(cert_acme_vhost)" || return 1
    grep -qF "$CERT_ACME_BEGIN" "$vhost" 2>/dev/null
}

# ----------------------------------------------------------------------
# Врезка с копией и откатом. Порядок важен: сначала проверяем собранный
# конфиг целиком (nginx -t), и только потом перезагружаем. Не собрался —
# возвращаем файл как был, иначе одна неудачная врезка уронила бы весь nginx,
# то есть и прокси.
# ----------------------------------------------------------------------
cert_acme_ensure() {
    local vhost backup tmp
    vhost="$(cert_acme_vhost)" || {
        echo "не нашёл единственный конфиг с listen 80 — врезать путь проверки некуда" >&2
        return 1
    }
    grep -qF "$CERT_ACME_BEGIN" "$vhost" 2>/dev/null && return 0

    mkdir -p "$CERT_BACKUP_DIR" 2>/dev/null
    chmod 700 "$CERT_BACKUP_DIR" 2>/dev/null
    backup="$CERT_BACKUP_DIR/$(basename "$vhost").before-acme"
    tmp="$(mktemp)" || return 1

    if ! cert_acme_insert < "$vhost" > "$tmp"; then
        rm -f "$tmp"
        echo "в $vhost не найден server{} с listen 80" >&2
        return 1
    fi

    cp -p "$vhost" "$backup" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$vhost" || { rm -f "$tmp"; cp -p "$backup" "$vhost"; return 1; }
    rm -f "$tmp"

    if ! nginx -t >/dev/null 2>&1; then
        cp -p "$backup" "$vhost"
        echo "nginx не принял конфиг с путём проверки — вернул как было" >&2
        return 1
    fi
    systemctl reload nginx >/dev/null 2>&1 || true
    return 0
}

# ----------------------------------------------------------------------
# Перевод renewal-файлов со standalone на webroot.
#
# ТРОГАЕМ ТОЛЬКО standalone. Кто проверяет владение доменом через DNS или
# плагином nginx — настроил это осознанно и порт 80 ему не нужен; переписать
# такую установку значило бы сломать работающее продление ради своего
# представления о правильном.
#
# webroot_map намеренно не пишем: для доменов, которых в нём нет, certbot
# берёт webroot_path. Проверено репетицией на стенде без карты.
# ----------------------------------------------------------------------
cert_renewal_standalone_files() {
    local f
    for f in "$CERT_RENEWAL_DIR"/*.conf; do
        [ -r "$f" ] || continue
        grep -qE '^authenticator = standalone[[:space:]]*$' "$f" && printf '%s\n' "$f"
    done
}

cert_renewal_webroot_ensure() {
    local f ok=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        mkdir -p "$CERT_BACKUP_DIR" 2>/dev/null
        chmod 700 "$CERT_BACKUP_DIR" 2>/dev/null
        cp -p "$f" "$CERT_BACKUP_DIR/$(basename "$f").before-webroot" 2>/dev/null
        sed -i 's/^authenticator = standalone[[:space:]]*$/authenticator = webroot/' "$f" || { ok=1; continue; }
        grep -qE '^webroot_path' "$f" || \
            sed -i "/^authenticator = webroot\$/a webroot_path = ${CERT_ACME_ROOT}," "$f" || ok=1
    done <<< "$(cert_renewal_standalone_files)"
    return "$ok"
}

# ----------------------------------------------------------------------
# Хук перезагрузки. Без него nginx держит в памяти прежний сертификат до
# ближайшего перезапуска: файл на диске свежий, наружу отдаётся просроченный,
# и причину такого искать долго.
# ----------------------------------------------------------------------
cert_hook_ensure() {
    mkdir -p "$CERT_HOOK_DIR" 2>/dev/null || return 1
    cat > "$CERT_HOOK_FILE" <<'EOF'
#!/bin/sh
# Поставлено VSM (lib/cert_renew.sh).
#
# Продлённый сертификат nginx подхватывает только после перезагрузки. Без
# этого файла на диске лежал бы свежий сертификат, а наружу отдавался старый —
# то есть просроченный. Затрагивает панель 3x-ui на 443, маскировку telemt и
# доступ к веб-панели.
systemctl reload nginx
EOF
    chmod 755 "$CERT_HOOK_FILE"
}

# ----------------------------------------------------------------------
# Состояние: что из трёх условий не выполнено. Пустой вывод — всё на месте.
# ----------------------------------------------------------------------
cert_renew_missing() {
    local missing=()
    [ -n "$(cert_renewal_standalone_files)" ] && missing+=("способ standalone")
    cert_acme_present || missing+=("нет пути проверки в nginx")
    [ -x "$CERT_HOOK_FILE" ] || missing+=("нет перезагрузки nginx")
    [ "${#missing[@]}" -eq 0 ] && return 0
    printf '%s\n' "${missing[*]}"
}

cert_renew_apply() {
    local rc=0
    cert_acme_ensure           || rc=1
    cert_renewal_webroot_ensure || rc=1
    cert_hook_ensure           || rc=1
    return "$rc"
}

# ----------------------------------------------------------------------
# ПОЗИЦИЯ РЕЕСТРА cert_renew
# ----------------------------------------------------------------------
# Применима там, где сертификатом занимается certbot и стоит nginx. На
# установке без certbot (3x-ui умеет выпускать и сам через acme.sh) спрашивать
# не о чем, и позиция молчит, а не объявляет расхождение на исправной машине.
applies_cert_renew() {
    command -v certbot >/dev/null 2>&1 || return 1
    command -v nginx   >/dev/null 2>&1 || return 1
    compgen -G "$CERT_RENEWAL_DIR/*.conf" >/dev/null 2>&1
}
want_cert_renew() { echo "настроено"; }
read_cert_renew() {
    local missing
    missing="$(cert_renew_missing)"
    if [ -z "$missing" ]; then echo "настроено"; else echo "$missing"; fi
}
fix_cert_renew() {
    cert_renew_apply || return 1
    [ -z "$(cert_renew_missing)" ]
}
