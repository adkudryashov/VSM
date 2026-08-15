#!/bin/bash

# ======================================================================
# МЕСТО НА ДИСКЕ: СНАЧАЛА ПОКАЗАТЬ, ПОТОМ УБРАТЬ
#
#   bash tools/disk-cleanup.sh                 отчёт, ничего не трогает
#   bash tools/disk-cleanup.sh --clean         убрать накопившийся мусор
#   bash tools/disk-cleanup.sh --logging-tune  устранить ПРИЧИНУ роста логов
#   bash tools/disk-cleanup.sh --logging-reset вернуть журналирование как было
#
# ЗАЧЕМ ОТДЕЛЬНО ОТ ПРЕЖНЕЙ ОЧИСТКИ. Пункт «Очистка системы» чистил кэш apt,
# зависимости и журнал — и не трогал самое крупное. На стенде замерено: 2 ГБ
# занимали РАСПАКОВАННЫЕ исходники, из которых собирали nginx с OpenSSL. После
# сборки они не нужны, архивы рядом остаются, пересборка распакует заново.
#
# И главное: уборка лечит следствие. Место кончалось потому, что journald по
# умолчанию дублирует ВСЁ в syslog, а telemt пишет сотни тысяч строк в сутки.
# Убрать один раз — значит вернуться к тому же через неделю. Поэтому причина
# вынесена в отдельное действие, которое МЕНЯЕТ НАСТРОЙКУ СИСТЕМЫ и потому
# спрашивается отдельно, а не входит в «выполнить всё сразу».
# ======================================================================

set -uo pipefail

JOURNAL_DROPIN=/etc/systemd/journald.conf.d/zz-vsm.conf
JOURNAL_CAP="${VSM_JOURNAL_CAP:-500M}"
SRC_DIR=/usr/local/src

RED=$'\e[1;31m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; CYAN=$'\e[1;36m'; DIM=$'\e[2m'; NC=$'\e[0m'
say() { printf '%s\n' "$*"; }
die() { printf '%s%s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Нужен root."

# Размер каталога в мегабайтах. Ноль, если каталога нет: отсутствие — не ошибка,
# на разных установках набор разный.
_mb() { du -sm "$1" 2>/dev/null | cut -f1 || echo 0; }

# ----------------------------------------------------------------------
# ОТЧЁТ
# ----------------------------------------------------------------------
report() {
    say ""
    say "${CYAN}МЕСТО НА ДИСКЕ${NC}"
    say "──────────────────────────────────────────────────────────────"
    df -h / | tail -1 | awk '{printf "  всего %s, занято %s (%s), свободно %s\n", $2, $3, $5, $4}'
    say ""

    say "${CYAN}ЧТО МОЖНО ОСВОБОДИТЬ${NC}"
    local total=0 n
    # Распакованные исходники: считаем ТОЛЬКО каталоги, архивы не трогаем —
    # они по 50 МБ и избавляют пересборку от повторной загрузки.
    n=0
    if [ -d "$SRC_DIR" ]; then
        local d
        for d in "$SRC_DIR"/*/; do
            [ -d "$d" ] && n=$((n + $(_mb "$d")))
        done
    fi
    [ "$n" -gt 0 ] && { printf '  %-42s %6s МБ\n' "распакованные исходники сборки" "$n"; total=$((total+n)); }

    n=$(_mb /var/cache/apt/archives)
    [ "$n" -gt 5 ] && { printf '  %-42s %6s МБ\n' "кэш скачанных пакетов" "$n"; total=$((total+n)); }

    # Журнал сверх потолка: освободится только превышение, а не весь объём.
    local jnow jcap_mb
    jnow=$(_mb /var/log/journal)
    jcap_mb=$(printf '%s' "$JOURNAL_CAP" | sed 's/M$//; s/G$/000/')
    if [ "$jnow" -gt "$jcap_mb" ]; then
        n=$((jnow - jcap_mb))
        printf '  %-42s %6s МБ\n' "журнал сверх потолка $JOURNAL_CAP" "$n"; total=$((total+n))
    fi

    n=0
    local f
    for f in /var/log/syslog /var/log/syslog.1 /var/log/syslog.*.gz; do
        [ -f "$f" ] && n=$((n + $(_mb "$f")))
    done
    [ "$n" -gt 5 ] && { printf '  %-42s %6s МБ\n' "syslog (дублирует журнал)" "$n"; total=$((total+n)); }

    n=$(dpkg -l 2>/dev/null | grep -c '^ii  linux-image-[0-9]')
    [ "$n" -gt 2 ] && printf '  %-42s %6s шт\n' "старых ядер сверх нужных двух" "$((n-2))"

    if [ "$total" -eq 0 ]; then
        say "  ${GREEN}Убирать нечего — накопившегося мусора нет.${NC}"
    else
        say "  ───────────────────────────────────────────────────────────"
        printf '  %-42s %6s МБ\n' "ИТОГО" "$total"
    fi

    # ------------------------------------------------------------------
    say ""
    say "${CYAN}СКОРОСТЬ РОСТА ЛОГОВ${NC}"
    say "${DIM}  Без этой цифры непонятно, почему место кончается снова.${NC}"

    local oldest days rate
    oldest=$(find /var/log/journal -name '*.journal*' -printf '%T@\n' 2>/dev/null | sort -n | head -1)
    if [ -n "${oldest:-}" ]; then
        local hours
        hours=$(( ( $(date +%s) - ${oldest%.*} ) / 3600 ))
        [ "$hours" -lt 1 ] && hours=1
        rate=$(( jnow * 24 / hours ))
        days=$(( hours / 24 ))
        if [ "$hours" -lt 48 ]; then
            # Окно короче двух суток — либо журнал недавно чистили, либо он
            # уже упёрся в потолок и крутится по кругу. В обоих случаях это
            # НИЖНЯЯ ГРАНИЦА, а не измерение: считать её точной цифрой значит
            # обмануть себя ровно там, где решают, хватит ли места.
            printf '  журнал: %s МБ за %s ч — не меньше %s МБ в сутки\n' "$jnow" "$hours" "$rate"
            say "${DIM}    (оценка грубая: журнал либо недавно чистили, либо он крутится по кругу)${NC}"
        else
            printf '  журнал: %s МБ за %s сут — около %s МБ в сутки\n' "$jnow" "$days" "$rate"
        fi
    fi

    # Кто пишет больше всех — по выборке последних строк, а не по всему
    # журналу: полный подсчёт на гигабайтном журнале идёт минутами.
    say "  главные источники (по выборке 5000 записей):"
    journalctl -n 5000 -o json --output-fields=_SYSTEMD_UNIT 2>/dev/null \
        | grep -oP '"_SYSTEMD_UNIT":"\K[^"]+' | sort | uniq -c | sort -rn | head -3 \
        | awk '{printf "    %-34s %s%%\n", $2, int($1/50)}'

    # ------------------------------------------------------------------
    say ""
    say "${CYAN}ПРИЧИНА РОСТА${NC}"
    if [ -f "$JOURNAL_DROPIN" ]; then
        say "  ${GREEN}✓${NC} потолок журнала и дублирование в syslog настроены VSM"
        say "${DIM}    вернуть как было: --logging-reset${NC}"
    else
        say "  ${YELLOW}!${NC} journald дублирует всё в syslog и не имеет явного потолка."
        say "    Значит убранное вернётся. Устранить: --logging-tune"
    fi
    say ""
}

# ----------------------------------------------------------------------
# УБОРКА
# ----------------------------------------------------------------------
clean() {
    local before after
    before=$(df -Pm / | awk 'NR==2 {print $4}')

    say "${CYAN}Убираю…${NC}"

    # Распакованные исходники. Архивы (*.tar.gz) ОСТАВЛЯЕМ: пересборка
    # проверяет наличие каталога и, не найдя его, скачивает и распаковывает
    # заново — проверено по коду stacks/nginx-openssl35.sh.
    if [ -d "$SRC_DIR" ]; then
        local d removed=0
        for d in "$SRC_DIR"/*/; do
            [ -d "$d" ] || continue
            rm -rf -- "$d" && removed=$((removed + 1))
        done
        [ "$removed" -gt 0 ] && say "  распакованных исходников удалено: $removed (архивы оставлены)"
    fi

    apt-get clean >/dev/null 2>&1 && say "  кэш пакетов очищен"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq >/dev/null 2>&1 \
        && say "  лишние пакеты и старые ядра удалены"

    journalctl --vacuum-size="$JOURNAL_CAP" >/dev/null 2>&1 \
        && say "  журнал ужат до $JOURNAL_CAP"

    # syslog: содержимое дублирует журнал, поэтому обнуляем текущий и сносим
    # ротированные. Обнуляем через ": >", а не rm: файл открыт rsyslog, и
    # удаление оставило бы его писать в никуда до перезапуска службы.
    rm -f /var/log/syslog.[0-9] /var/log/syslog.*.gz 2>/dev/null
    [ -f /var/log/syslog ] && : > /var/log/syslog && say "  syslog обнулён (содержимое есть в журнале)"

    after=$(df -Pm / | awk 'NR==2 {print $4}')
    say ""
    say "${GREEN}Освобождено: $(( after - before )) МБ.${NC} Свободно сейчас: $(( after )) МБ."
    say "${DIM}Чтобы не вернулось — устраните причину: --logging-tune${NC}"
}

# ----------------------------------------------------------------------
# ПРИЧИНА
# ----------------------------------------------------------------------
logging_tune() {
    mkdir -p "$(dirname "$JOURNAL_DROPIN")" || die "Не создать каталог настроек journald."
    cat > "$JOURNAL_DROPIN" <<EOF
# Поставлено VSM: меню «Утилиты» → «Очистка системы».
# Снять: bash tools/disk-cleanup.sh --logging-reset
#
# SystemMaxUse — явный потолок вместо умолчания «10% файловой системы».
# ForwardToSyslog=no — journald по умолчанию дублирует ВСЁ в syslog. На сервере
# с прокси это сотни тысяч строк в сутки, записанных дважды. Ничего не
# теряется: всё читается через journalctl.
[Journal]
SystemMaxUse=$JOURNAL_CAP
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald || die "journald не перезапустился — настройка не применена."
    sleep 1
    # Проверяем фактом: настройка обязана быть видна в разобранном конфиге.
    if systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -q '^ForwardToSyslog=no'; then
        _remember on
        say "${GREEN}✓ Готово.${NC} Журнал ограничен $JOURNAL_CAP, дублирование в syslog выключено."
        say "${DIM}  Логи по-прежнему читаются: journalctl -u <служба>${NC}"
        say "${DIM}  Сверка с реестром теперь скажет, если настройку собьёт чужое обновление.${NC}"
    else
        die "Настройка записана, но journald её не подхватил — проверьте $JOURNAL_DROPIN"
    fi
}

logging_reset() {
    [ -f "$JOURNAL_DROPIN" ] || { say "Настройка VSM не стоит — возвращать нечего."; _remember off; return 0; }
    rm -f "$JOURNAL_DROPIN"
    systemctl restart systemd-journald || die "journald не перезапустился."
    # Снимаем отметку: выключение владельцем — это решение, а не поломка, и
    # сверка не должна о нём напоминать.
    _remember off
    say "${GREEN}✓ Возвращены умолчания системы.${NC}"
}

# Запоминает решение владельца в том же файле состояния, что и остальной
# реестр. Позиция journal_limits опирается на эту отметку, а не на наличие
# файла: иначе снесённая настройка выглядела бы как «вы её и не включали».
_remember() {
    local lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/expectations.sh"
    [ -r "$lib" ] || return 0
    # shellcheck source=/dev/null
    . "$lib" 2>/dev/null || return 0
    _state_set journal_limits "$1" 2>/dev/null || true
}

# ----------------------------------------------------------------------
case "${1:-}" in
    ""|--report)     report ;;
    --clean)         clean ;;
    --logging-tune)  logging_tune ;;
    --logging-reset) logging_reset ;;
    -h|--help)       sed -n '3,25p' "$(readlink -f "${BASH_SOURCE[0]}")" ;;
    *)               die "Неизвестный аргумент: $1" ;;
esac
