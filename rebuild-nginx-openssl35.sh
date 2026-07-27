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
# ============================================================================

OPENSSL_VER="${OPENSSL_VER:-3.5.6}"
NGINX_VER="${NGINX_VER:-}"

log()  { echo -e "\e[1;32m[этап]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m    $*"; }
die()  { echo -e "\e[1;31m[СБОЙ]\e[0m $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Запускай под root."
command -v nginx >/dev/null || die "nginx не установлен."

[[ -n "$NGINX_VER" ]] || NGINX_VER="$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')"
[[ -n "$NGINX_VER" ]] || die "Не удалось определить версию nginx."

AVAIL_MB="$(df -Pm /usr/local/src | awk 'NR==2 {print $4}')"
[[ "${AVAIL_MB:-0}" -ge 2048 ]] || die "Нужно минимум 2 ГБ свободного места в /usr/local/src (доступно ${AVAIL_MB} МБ)."

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
# 1. OpenSSL 3.5.x в изолированный префикс
# ---------------------------------------------------------------------------
log "Этап 1: сборка OpenSSL ${OPENSSL_VER} (долго)"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential zlib1g-dev perl libpcre2-dev wget

cd /usr/local/src
if [[ ! -d "openssl-${OPENSSL_VER}" ]]; then
    wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" \
        || die "Не удалось скачать OpenSSL ${OPENSSL_VER}."
    tar xzf "openssl-${OPENSSL_VER}.tar.gz"
fi
cd "openssl-${OPENSSL_VER}"
./Configure --prefix=/opt/openssl-3.5 --openssldir=/opt/openssl-3.5/ssl shared
make -j"$(nproc)"
log "OpenSSL собран."

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

./objs/nginx -V 2>&1 | grep -q "OpenSSL ${OPENSSL_VER}" \
    || die "Собранный бинарник не показывает OpenSSL ${OPENSSL_VER} — установка отменена, система не тронута."

# ---------------------------------------------------------------------------
# 3. Подмена бинарника с откатом
# ---------------------------------------------------------------------------
log "Этап 3: установка нового бинарника"

BACKUP=/usr/sbin/nginx.pre-openssl35.bak
MODS_BACKUP=/etc/nginx/modules-enabled.pre-openssl35.bak

cp /usr/sbin/nginx "$BACKUP"
systemctl stop nginx
cp ./objs/nginx /usr/sbin/nginx

# Модули теперь встроены статически. Ubuntu подключает их через отдельные
# файлы в /etc/nginx/modules-enabled/ (относительным путём), а не строкой
# load_module в nginx.conf — иначе nginx падает с "module already loaded".
if [[ -d /etc/nginx/modules-enabled ]] && compgen -G "/etc/nginx/modules-enabled/*" >/dev/null; then
    cp -a /etc/nginx/modules-enabled "$MODS_BACKUP"
    rm -f /etc/nginx/modules-enabled/*
    log "  директивы load_module убраны (бэкап: $MODS_BACKUP)"
fi
sed -i '/^\s*load_module.*ngx_stream_module\.so;/d' /etc/nginx/nginx.conf

rollback() {
    warn "Откатываюсь на прежний бинарник..."
    cp "$BACKUP" /usr/sbin/nginx
    [[ -d "$MODS_BACKUP" ]] && cp -a "$MODS_BACKUP"/. /etc/nginx/modules-enabled/ 2>/dev/null || true
    if nginx -t >/dev/null 2>&1; then
        systemctl start nginx && log "nginx поднят на прежней версии."
    else
        systemctl start nginx 2>/dev/null || true
        warn "nginx -t не проходит даже после отката — проверь конфиг вручную!"
    fi
}

if ! nginx -t; then
    rollback
    die "nginx -t упал после подмены бинарника. Откат выполнен, сервис работает на старом nginx."
fi

if ! systemctl start nginx; then
    rollback
    die "nginx не стартовал с новым бинарником. Откат выполнен."
fi

systemctl status nginx --no-pager || true
apt-mark hold nginx nginx-common nginx-full >/dev/null 2>&1 || true

log "Готово:"
nginx -V 2>&1 | grep "OpenSSL"

cat << SUMMARY

════════════════════════════════════════════════════════════════
nginx пересобран с OpenSSL ${OPENSSL_VER}, пакеты захолжены (apt-mark hold).

Бэкап бинарника: ${BACKUP}
Бэкап modules-enabled: ${MODS_BACKUP}

ВАЖНО: пакет захолжен — security-обновления nginx больше не приедут
автоматически. При выходе новой версии повтори пересборку вручную.

Проверка PQ-поддержки (нужен клиентский OpenSSL 3.5+):
  export PATH="/opt/openssl-3.5/bin:\$PATH"
  export LD_LIBRARY_PATH="/opt/openssl-3.5/lib64:\$LD_LIBRARY_PATH"
  openssl s_client -connect <IP>:<порт telemt> -groups X25519MLKEM768
════════════════════════════════════════════════════════════════
SUMMARY
