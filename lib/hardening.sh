# shellcheck shell=bash
# Защита сервера, которой не даёт ни один компонент стека:
#   • нарастающий бан подбора пароля SSH (fail2ban);
#   • обновления безопасности раз в 30 дней.
#
# ЗАЧЕМ. Разбор главного сервера 25.09.2026: root входит по паролю (ключ
# владелец ставить не хочет), за сутки 2339 неудачных попыток с 14 адресов, а
# fail2ban не стоял — 3x-ui ставит его только при обновлении через своё меню.
# Обновления выключил образ хостера: файлом в apt.conf.d и масками на пяти
# юнитах. 94 обновления безопасности ждали установки, и никто об этом не знал.
#
# ЛЕСТНИЦА. 3 неудачи за час с одного адреса — бан. Каждый следующий бан того
# же адреса длиннее: 15 мин, 1 ч, сутки, неделя, месяц, год, дальше год. Это
# штатный bantime.increment fail2ban, своего кода нет. Проверено тестовой
# тюрьмой на поддельном журнале: 5 → 20 → 480 с, то есть ×1, ×4, ×96.
#
# ПАМЯТЬ БАНОВ. По умолчанию fail2ban забывает историю через сутки
# (dbpurgeage = 1d), и лестница каждый раз начиналась бы с 15 минут. Храним
# 400 дней. Диск замерен на стенде: 302 бана в сутки с 68 адресов, ~0,9 КБ на
# запись. С лестницей повторных банов меньше (адрес сидит в бане, а не
# набирает новые), dbmaxmatches = 3 вместо 10 ужимает запись — выходит порядка
# десятков мегабайт за год.
#
# СВОИ ФАЙЛЫ, ЧУЖИЕ НЕ ПРАВИМ. jail.d/zz-vsm-sshd.local и fail2ban.d/zz-vsm.local
# читаются последними и перекрывают умолчания; обновление пакета .local не
# трогает. Для apt — 99zz-vsm-…: имя сортируется после файла хостера
# 99-hostup-disable-automatic-apt, который выключает всё, и потому побеждает.
#
# ПЕРЕЗАГРУЗКИ НЕТ. Новое ядро заработает после ручной перезагрузки. Службы на
# обновлённых библиотеках перезапускает needrestart сам — telemt, nginx и
# панель моргнут на секунды раз в месяц.

HARD_F2B_JAIL="${HARD_F2B_JAIL:-/etc/fail2ban/jail.d/zz-vsm-sshd.local}"
HARD_F2B_CONF="${HARD_F2B_CONF:-/etc/fail2ban/fail2ban.d/zz-vsm.local}"
HARD_APT_CONF="${HARD_APT_CONF:-/etc/apt/apt.conf.d/99zz-vsm-monthly-upgrades}"
HARD_LADDER_RETRY=3
HARD_LADDER_MULT="1 4 96 672 2880 35040"
HARD_UPDATE_DAYS="${HARD_UPDATE_DAYS:-30}"
# Замаскированное хостером. Сервисы тоже: без них таймер отказывается
# стартовать («unit to trigger not loaded») — снятия масок с одних таймеров мало.
HARD_APT_UNITS=(apt-daily.timer apt-daily.service apt-daily-upgrade.timer
                apt-daily-upgrade.service unattended-upgrades.service)

_hd_fail() { echo -e "${RED:-}❌ $*${NC:-}" >&2; return 1; }
_hd_say()  { echo -e "${C_DESC:-}   $*${NC:-}"; }
_hd_ok()   { echo -e "${GREEN:-}✔ $*${NC:-}"; }

# Реестр подключён — запоминаем решение владельца: сверка следит за тем, что
# включено меню, а осознанное выключение расхождением не считает.
_hd_remember() { declare -F _state_set >/dev/null && _state_set "$1" "$2" 2>/dev/null; return 0; }

# ----------------------------------------------------------------------
# Содержимое файлов. Отдельно от записи — чтобы тесты видели ровно то, что
# ляжет на сервер.
# ----------------------------------------------------------------------

ssh_ladder_render_jail() {
    cat <<EOF
# VSM: нарастающий бан за подбор пароля SSH. Пишет «Настройка» → «Бан подбора
# SSH» (lib/hardening.sh); правка руками будет возвращена сверкой.
# ${HARD_LADDER_RETRY} неудачи за час с одного адреса — бан. Каждый следующий бан того же
# адреса длиннее: 15 мин, 1 ч, сутки, неделя, месяц, год, дальше год.
[sshd]
enabled  = true
mode     = aggressive
maxretry = ${HARD_LADDER_RETRY}
findtime = 1h
bantime  = 15m
bantime.increment   = true
bantime.multipliers = ${HARD_LADDER_MULT}
bantime.maxtime     = 365d
EOF
}

ssh_ladder_render_f2b() {
    cat <<'EOF'
# VSM: история банов живёт дольше самой длинной ступени лестницы (год).
# С умолчанием 1d лестница каждый раз начиналась бы с 15 минут.
# dbmaxmatches: строк журнала на запись — для лестницы они не нужны.
[DEFAULT]
dbpurgeage   = 400d
dbmaxmatches = 3
EOF
}

updates_render_apt() {
    cat <<EOF
// VSM: обновления безопасности раз в ${HARD_UPDATE_DAYS} дней. Пишет «Настройка» →
// «Автообновления» (lib/hardening.sh). Имя сортируется после файлов хостера
// и потому перекрывает их. Списки пакетов — ежедневно (дёшево), установка —
// не чаще раза в ${HARD_UPDATE_DAYS} дней по отметке apt.systemd.daily.
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "${HARD_UPDATE_DAYS}";
APT::Periodic::AutocleanInterval "${HARD_UPDATE_DAYS}";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
}

# Файл целиком или никак: временный рядом и mv. fail2ban и apt читают только
# *.conf/*.local и имена без точки — временное имя не подхватит ни один.
_hd_write() {
    local file="$1" render="$2" tmp
    mkdir -p "$(dirname "$file")" || return 1
    tmp="$(mktemp "${file}.vsm-tmp.XXXXXX")" || return 1
    "$render" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$file" && return 0
    rm -f "$tmp"; return 1
}

# ----------------------------------------------------------------------
# Бан подбора пароля SSH
# ----------------------------------------------------------------------

# Первое число из ответа fail2ban-client: «900», «`- 34560000seconds».
_hd_f2b_num() {
    fail2ban-client get "$@" 2>/dev/null | tr -dc '0-9\n' | grep -m1 -E '^[0-9]+$'
}

# Что ДЕЙСТВУЕТ, а не что записано в файлах: fail2ban спрашивается напрямую,
# иначе чужой .local с именем позже нашего перебил бы настройку незаметно.
ssh_ladder_state() {
    command -v fail2ban-client >/dev/null 2>&1 || { echo "fail2ban не установлен"; return; }
    systemctl is-active --quiet fail2ban 2>/dev/null || { echo "fail2ban остановлен"; return; }
    fail2ban-client status sshd >/dev/null 2>&1 || { echo "защита SSH выключена"; return; }
    local retry ban inc mult purge
    retry="$(_hd_f2b_num sshd maxretry)"
    ban="$(_hd_f2b_num sshd bantime)"
    inc="$(fail2ban-client get sshd bantime.increment 2>/dev/null)"
    mult="$(fail2ban-client get sshd bantime.multipliers 2>/dev/null | tr -s ' \t' ' ' | sed 's/^ //; s/ $//')"
    purge="$(_hd_f2b_num dbpurgeage)"
    if [ "$inc" != "True" ] || [ "$mult" != "$HARD_LADDER_MULT" ] \
       || [ "$retry" != "$HARD_LADDER_RETRY" ] || [ "$ban" != "900" ]; then
        echo "штатные сроки, без лестницы"
    elif [ "${purge:-0}" -lt 31536000 ]; then
        echo "лестница без памяти на год"
    else
        echo "действует"
    fi
}

ssh_ladder_banned() {
    fail2ban-client status sshd 2>/dev/null | grep -oP 'Currently banned:\s*\K[0-9]+'
}

_hd_install_pkg() {
    local pkg="$1" cmd="$2"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    if declare -F ensure_packages >/dev/null; then
        ensure_packages "${pkg}:${cmd}"
    else
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y "$pkg" >/dev/null 2>&1
        command -v "$cmd" >/dev/null 2>&1
    fi
}

# Вернуть свои файлы из копии; файла в копии не было — значит и не было его.
_hd_restore() {
    local bak="$1" f
    for f in "$HARD_F2B_JAIL" "$HARD_F2B_CONF"; do
        if [ -f "$bak/$(basename "$f")" ]; then cp -a "$bak/$(basename "$f")" "$f"; else rm -f "$f"; fi
    done
}

ssh_ladder_enable() {
    _hd_install_pkg fail2ban fail2ban-client || { _hd_fail "fail2ban не установился."; return 1; }

    # Прежние версии своих файлов — чтобы откатиться, если fail2ban их не примет.
    local bak f
    bak="$(mktemp -d)" || return 1
    for f in "$HARD_F2B_JAIL" "$HARD_F2B_CONF"; do
        [ -f "$f" ] && cp -a "$f" "$bak/$(basename "$f")"
    done

    if ! _hd_write "$HARD_F2B_JAIL" ssh_ladder_render_jail \
       || ! _hd_write "$HARD_F2B_CONF" ssh_ladder_render_f2b; then
        _hd_restore "$bak"; rm -rf "$bak"; _hd_fail "Не удалось записать настройки fail2ban."; return 1
    fi
    if ! fail2ban-client -t >/dev/null 2>&1; then
        _hd_restore "$bak"; rm -rf "$bak"
        _hd_fail "fail2ban не принял настройки — возвращено как было (подробно: fail2ban-client -t)."
        return 1
    fi
    rm -rf "$bak"

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban || { _hd_fail "fail2ban не перезапустился."; return 1; }
    # Сокет fail2ban поднимается не сразу после restart.
    local i state=""
    for ((i = 0; i < 20; i++)); do
        state="$(ssh_ladder_state)"
        [ "$state" = "действует" ] && break
        sleep 1
    done
    [ "$state" = "действует" ] || { _hd_fail "После перезапуска: ${state:-нет ответа}."; return 1; }
    _hd_remember ssh_ladder on
    _hd_ok "Лестница бана действует: ${HARD_LADDER_RETRY} неудачи за час → 15 мин, 1 ч, сутки, неделя, месяц, год."
}

ssh_ladder_disable() {
    rm -f "$HARD_F2B_JAIL" "$HARD_F2B_CONF"
    if command -v fail2ban-client >/dev/null 2>&1; then
        systemctl restart fail2ban 2>/dev/null || true
        sleep 2
    fi
    _hd_remember ssh_ladder off
    _hd_ok "Лестница снята. Сейчас: $(ssh_ladder_state)."
}

# Снять бан и забыть историю адреса: иначе следующая же опечатка поставит его
# на следующую ступень, а не на первую. Нужна прежде всего владельцу, который
# забанил сам себя и вошёл через консоль хостера.
ssh_ladder_unban() {
    local ip="$1" db
    if ! [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ip" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$ ]]; then
        _hd_fail "Это не адрес IPv4 или IPv6: ${ip}"; return 1
    fi
    command -v fail2ban-client >/dev/null 2>&1 || { _hd_fail "fail2ban не установлен."; return 1; }
    fail2ban-client unban "$ip" >/dev/null 2>&1
    db="$(fail2ban-client get dbfile 2>/dev/null | grep -oE '/[^ ]+\.sqlite3' | head -1)"
    if [ -n "$db" ] && [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
        # Адрес проверен выражением выше — кавычке в нём взяться неоткуда.
        sqlite3 -cmd ".timeout 5000" "$db" \
            "delete from bans where ip='${ip}'; delete from bips where ip='${ip}';" 2>/dev/null \
            || _hd_say "История адреса не стёрта — следующий бан будет длиннее."
    fi
    if fail2ban-client banned "$ip" 2>/dev/null | grep -q "'"; then
        _hd_fail "Адрес ${ip} всё ещё в бане."; return 1
    fi
    _hd_ok "Адрес ${ip} не забанен, история забыта."
}

# ----------------------------------------------------------------------
# Автообновления
# ----------------------------------------------------------------------

_hd_apt_val() { apt-config dump 2>/dev/null | grep -m1 -oP "^$1 \"\K[^\"]*"; }

updates_state() {
    command -v unattended-upgrade >/dev/null 2>&1 || { echo "unattended-upgrades не установлен"; return; }
    local u
    for u in "${HARD_APT_UNITS[@]}"; do
        [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "masked" ] && { echo "выключены масками"; return; }
    done
    [ "$(_hd_apt_val APT::Periodic::Enable)" = "0" ] && { echo "выключены настройкой apt"; return; }
    local days
    days="$(_hd_apt_val APT::Periodic::Unattended-Upgrade)"
    case "${days:-0}" in
        0) echo "выключены"; return ;;
    esac
    systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null || { echo "таймер не запущен"; return; }
    case "$days" in
        1|always) echo "каждый день" ;;
        *)        echo "раз в ${days} дн." ;;
    esac
}

updates_last_run() {
    local s=/var/lib/apt/periodic/upgrade-stamp
    [ -f "$s" ] && date -r "$s" '+%d.%m.%Y' || echo "ещё не было"
}

updates_monthly_enable() {
    _hd_install_pkg unattended-upgrades unattended-upgrade \
        || { _hd_fail "unattended-upgrades не установился."; return 1; }
    _hd_write "$HARD_APT_CONF" updates_render_apt || { _hd_fail "Не удалось записать ${HARD_APT_CONF}."; return 1; }
    systemctl unmask "${HARD_APT_UNITS[@]}" >/dev/null 2>&1
    systemctl daemon-reload
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    local state; state="$(updates_state)"
    [ "$state" = "раз в ${HARD_UPDATE_DAYS} дн." ] || { _hd_fail "После настройки: ${state}."; return 1; }
    _hd_remember monthly_updates on
    _hd_ok "Обновления безопасности — раз в ${HARD_UPDATE_DAYS} дней, без перезагрузки."
}

# Возвращает то, что было до VSM: свой файл убираем, маски хостера НЕ
# возвращаем — их снятие было решением, а возврат к умолчаниям системы значит
# ежедневные обновления, на которые Ubuntu настроена изначально.
updates_monthly_disable() {
    rm -f "$HARD_APT_CONF"
    _hd_remember monthly_updates off
    _hd_ok "Настройка VSM снята. Сейчас: $(updates_state)."
}
