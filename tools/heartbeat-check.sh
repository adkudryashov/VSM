#!/bin/bash

# ======================================================================
# СТОРОЖ ДЛЯ СТОРОЖА
#
# Запускается таймером systemd раз в пять минут и НЕ ЗАВИСИТ от бота: шлёт в
# Telegram сам, обычным curl. В этом весь смысл — уведомлять о том, что бот
# умер, силами самого бота нельзя.
#
# ЗАЧЕМ ЭТО ВООБЩЕ. Сторож telemt — единственный источник тревог, и его
# молчание снаружи неотличимо от «всё хорошо». Аудит показал три способа
# замолчать незаметно:
#
#   1. Служба остановлена или не поднялась — тревог просто нет.
#   2. Петля перезапусков. Замерено на стенде с испорченным .env: три
#      перезапуска в минуту, systemd не сдаётся НИКОГДА (StartLimitBurst не
#      срабатывает, потому что RestartSec больше окна StartLimitInterval), и
#      всё это время `systemctl is-active` отвечает active.
#   3. Зависшая корутина. Процесс жив, служба active, счётчик перезапусков не
#      растёт, а цикл сторожа стоит. Ни один признак systemd этого не видит.
#
# Поэтому проверяем ФАКТОМ: состояние службы, ПРИРОСТ счётчика перезапусков за
# интервал и свежесть отметки, которую цикл ставит сам (watchdog.heartbeat).
#
#   bash tools/heartbeat-check.sh          обычный прогон
#   bash tools/heartbeat-check.sh --test    послать пробное сообщение и выйти
#   bash tools/heartbeat-check.sh --dry-run проверить и напечатать, не отправляя
# ======================================================================

set -uo pipefail

SERVICE="${HEARTBEAT_SERVICE:-3xui-telemt-bot}"
VSM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ENV_FILE="${HEARTBEAT_ENV:-$VSM_ROOT/bots/.env}"
BEAT_FILE="${HEARTBEAT_FILE:-$VSM_ROOT/bots/data/watchdog.heartbeat}"
STATE_FILE="${HEARTBEAT_STATE:-/etc/vsm/heartbeat.state}"

# Сколько минут без отметки считать зависанием. Цикл ходит раз в минуту
# (WATCHDOG_INTERVAL_SECONDS=60), но один прогон проверки доступности из РФ
# занимает до минуты, поэтому запас щедрый: ложная тревога о зависании хуже,
# чем узнать о нём на десять минут позже.
STALE_MINUTES="${HEARTBEAT_STALE_MINUTES:-15}"

# Сколько перезапусков за интервал считать петлёй. Один — это штатное
# обновление или ручной рестарт, о котором кричать не надо.
LOOP_RESTARTS="${HEARTBEAT_LOOP_RESTARTS:-2}"

# Как часто напоминать о продолжающейся беде. Тот же срок, что у тревог
# самого сторожа: молчать нельзя, тараторить раз в пять минут — тоже.
REPEAT_SECONDS="${HEARTBEAT_REPEAT_SECONDS:-1800}"

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    --test)    DRY_RUN=2 ;;
esac

# ----------------------------------------------------------------------
# Отправка. Токен и адресаты читаются из .env бота.
# ----------------------------------------------------------------------
_env_value() {
    [ -r "$ENV_FILE" ] || return 0
    grep -m1 -oP "^$1=\K.*" "$ENV_FILE" 2>/dev/null | tr -d '"'"'"' \r'
}

_token() {
    local t
    for key in COMBINED_BOT_TOKEN TELEMT_BOT_TOKEN XUI_BOT_TOKEN; do
        t="$(_env_value "$key")"
        [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    done
    return 1
}

# ADMIN_IDS лежит списком вида [123,456]. Достаём числа, а не разбираем JSON:
# тащить сюда python ради одной строки незачем, а формат задан нами же.
_admins() { _env_value ADMIN_IDS | tr -dc '0-9,' | tr ',' '\n' | grep -v '^$'; }

notify() {
    local text="$1" token admin sent=0
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'НЕ ОТПРАВЛЕНО (--dry-run):\n%s\n' "$text"
        return 0
    fi
    token="$(_token)" || { echo "Не нашёл токен в $ENV_FILE" >&2; return 1; }
    while read -r admin; do
        [ -n "$admin" ] || continue
        # --data-urlencode: в тексте есть переводы строк и кириллица.
        if curl -sS --max-time 20 -o /dev/null \
            "https://api.telegram.org/bot${token}/sendMessage" \
            --data-urlencode "chat_id=${admin}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML"; then
            sent=$((sent + 1))
        fi
    done < <(_admins)
    [ "$sent" -gt 0 ]
}

if [ "$DRY_RUN" -eq 2 ]; then
    notify "🩺 Проверка связи от сторожа-наблюдателя. Если вы это читаете — путь уведомлений работает." \
        && echo "отправлено" || { echo "отправить не удалось" >&2; exit 1; }
    exit 0
fi

# ----------------------------------------------------------------------
# Состояние между запусками: прошлый счётчик перезапусков и что мы уже
# сообщали. Без него о продолжающейся беде писали бы каждые пять минут.
# ----------------------------------------------------------------------
PREV_RESTARTS=0; PREV_TROUBLE=""; PREV_NOTIFY=0
if [ -r "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE" 2>/dev/null || true
    PREV_RESTARTS="${PREV_RESTARTS:-0}"
    PREV_TROUBLE="${PREV_TROUBLE:-}"
    PREV_NOTIFY="${PREV_NOTIFY:-0}"
fi

save_state() {
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
    ( umask 077
      printf 'PREV_RESTARTS=%q\nPREV_TROUBLE=%q\nPREV_NOTIFY=%q\n' \
          "$1" "$2" "$3" > "$STATE_FILE" )
}

# ----------------------------------------------------------------------
# Собственно проверки
# ----------------------------------------------------------------------
NOW="$(date +%s)"
RESTARTS="$(systemctl show "$SERVICE" -p NRestarts --value 2>/dev/null)"
[[ "$RESTARTS" =~ ^[0-9]+$ ]] || RESTARTS=0
ACTIVE="$(systemctl is-active "$SERVICE" 2>/dev/null)"
ENABLED="$(systemctl is-enabled "$SERVICE" 2>/dev/null)"

TROUBLE=""; MESSAGE=""

# Осознанно выключенная служба — не авария. Иначе тот, кто отключил бота
# намеренно, получал бы напоминание об этом раз в полчаса до конца времён.
if [ "$ENABLED" = "disabled" ] || [ "$ENABLED" = "masked" ]; then
    TROUBLE=""
elif [ "$ACTIVE" != "active" ]; then
    TROUBLE="служба"
    MESSAGE="🆘 <b>БОТ НЕ РАБОТАЕТ</b>
Служба <code>${SERVICE}</code>: ${ACTIVE:-неизвестно}.

Тревог от сторожа сейчас НЕ БУДЕТ — ни о прокси, ни о доступности.
Поднять: <code>systemctl start ${SERVICE}</code>
Причина: <code>journalctl -u ${SERVICE} -n 50</code>"
elif [ $((RESTARTS - PREV_RESTARTS)) -ge "$LOOP_RESTARTS" ]; then
    TROUBLE="петля"
    MESSAGE="🆘 <b>БОТ В ПЕТЛЕ ПЕРЕЗАПУСКОВ</b>
Перезапусков с прошлой проверки: $((RESTARTS - PREV_RESTARTS)).

Служба числится живой, но падает и поднимается снова. Тревоги при этом
теряются. Чаще всего причина — испорченный <code>bots/.env</code>.
Причина: <code>journalctl -u ${SERVICE} -n 50</code>"
elif [ -f "$BEAT_FILE" ]; then
    BEAT_AGE=$(( (NOW - $(stat -c %Y "$BEAT_FILE" 2>/dev/null || echo "$NOW")) / 60 ))
    if [ "$BEAT_AGE" -ge "$STALE_MINUTES" ]; then
        TROUBLE="зависание"
        MESSAGE="🆘 <b>ЦИКЛ СТОРОЖА ВСТАЛ</b>
Последний проход был ${BEAT_AGE} мин назад.

Процесс жив и служба активна, но сторож не опрашивает движок — значит
не заметит и аварии. Лечится перезапуском:
<code>systemctl restart ${SERVICE}</code>"
    fi
fi
# Отсутствие файла отметки НЕ тревога: сторож может быть выключен настройкой
# WATCHDOG_ENABLED, и жаловаться на это — значит спорить с решением владельца.

# ----------------------------------------------------------------------
# Решение: сообщать или молчать
# ----------------------------------------------------------------------
if [ -n "$TROUBLE" ]; then
    if [ "$TROUBLE" != "$PREV_TROUBLE" ] || [ $((NOW - PREV_NOTIFY)) -ge "$REPEAT_SECONDS" ]; then
        notify "$MESSAGE" && PREV_NOTIFY="$NOW"
    fi
    save_state "$RESTARTS" "$TROUBLE" "$PREV_NOTIFY"
    exit 1
fi

# Отбой — только если до этого была беда. Иначе каждый прогон на исправной
# системе слал бы «всё хорошо».
if [ -n "$PREV_TROUBLE" ]; then
    notify "✅ <b>Бот снова работает.</b>
Служба <code>${SERVICE}</code> активна, сторож опрашивает движок."
fi
save_state "$RESTARTS" "" "0"
exit 0
