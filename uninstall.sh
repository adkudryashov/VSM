#!/bin/bash

# ======================================================================
# УДАЛЕНИЕ VSM
#
# Порядок важен: сначала снимаются ссылки и службы, которые ССЫЛАЮТСЯ на
# каталог, и только потом удаляется сам каталог. Обратный порядок оставлял бы
# работающие таймеры, которые каждые пять минут дёргают несуществующий скрипт,
# и systemd-юниты с путями в никуда.
#
# ЧТО ИМЕННО УДАЛЯЕТСЯ И ЧТО НЕТ. Скрипт снимает только то, что поставил сам
# VSM: ссылки в /usr/local/bin, юниты ботов, свои таймеры, автозапуск в
# ~/.bashrc и каталог репозитория. Секреты (/etc/vsm) и суточные копии
# (/var/backups/vsm) удаляются ОТДЕЛЬНЫМ вопросом: в них пароли панелей и
# TELEMT_SECRET, и молча стирать их при «удалении меню» нельзя — владелец может
# рассчитывать забрать копию перед сносом сервера.
#
# ЧЕГО СКРИПТ НЕ ДЕЛАЕТ. Не снимает блоки nginx, правила UFW, fail2ban и
# сертификаты. Это настройки чужих компонентов, и удалять их вслепую из
# скрипта, который к тому же уже снёс меню, — значит оставить сервер в
# состоянии, которое нечем проверить. Об этом печатается предупреждение в
# начале и в конце.
#
# ПОДТВЕРЖДЕНИЯ. Разрушающие шаги требуют слова целиком (УДАЛИТЬ / ДА), а не
# «y»: правило проекта, и здесь оно важнее обычного — обратной операции нет.
# ======================================================================

set -uo pipefail

# Пути вынесены в переменные с умолчаниями не ради красоты: проверки
# (tests/test_uninstall.py) подставляют сюда временные каталоги, иначе прогон
# снёс бы настоящую установку. Те же имена, что у install.sh, чтобы не
# заводить второй набор.
TARGET_DIR="${VSM_TARGET_DIR:-/root/VSM}"
ETC_DIR="${VSM_ETC_DIR:-/etc/vsm}"
BACKUP_DIR="${VSM_BACKUP_DIR:-/var/backups/vsm}"
UNIT_DIR="${VSM_UNIT_DIR:-/etc/systemd/system}"
MAP_DIR="${VSM_MAP_DIR:-/var/www/telemt-map}"
BASHRC="${VSM_BASHRC:-$HOME/.bashrc}"

# Строки автозапуска. Удаляем ровно их, а не всё, где встречается «vsm»:
# прежняя версия делала `sed -i '/vsm/d'` и уносила из .bashrc любые чужие
# строки с этим словом — алиасы, PATH, комментарии.
BASHRC_COMMENT='# Автозапуск основного меню'
BASHRC_LINE='if [[ -t 0 ]]; then vsm; fi'
BASHRC_LINE_OLD='if [[ -t 0 ]]; then server-menu; fi'

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

say()  { echo -e "$*"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }
die()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

# Счёт неудач. Итог печатается по факту, а не по факту вызова: «Удаление
# завершено» поверх оставшегося каталога — ровно тот дефект, ради которого
# проект и завёл правило «проверять результат фактом».
FAIL=0

# Проверка root. VSM_UNINSTALL_FORCE=1 — только для автотестов на машине
# сборщика: под root они не гоняются, а проверять логику удаления надо.
if [ "$(id -u)" -ne 0 ] && [ "${VSM_UNINSTALL_FORCE:-0}" != "1" ]; then
    die "Нужен root: без него ссылки и юниты не снять, а отчёт будет ложным."
fi

# Слово целиком, без учёта регистра не принимаем: регистр — часть защиты от
# случайного нажатия.
ask_word() {
    local word="$1" prompt="$2" answer
    read -r -p "$prompt" answer || return 1
    [ "$answer" = "$word" ]
}

# ----------------------------------------------------------------------
# 1. Ссылки в /usr/local/bin
#
# Перебором по ЦЕЛИ ссылки, а не поимённо: список имён отставал от install.sh
# и оставлял битые ссылки на menus/xui.sh, stacks/telemt.sh и другие.
# readlink -f разрешает путь и у оборванной ссылки, поэтому ссылка на уже
# удалённый каталог тоже попадает под правило.
#
# Чужие битые ссылки НЕ трогаем: прежняя версия добивала в /usr/local/bin всё,
# что указывает в никуда, — то есть чистила не только за собой.
# ----------------------------------------------------------------------
remove_links() {
    local removed=0 link target
    for link in /usr/local/bin/*; do
        [ -L "$link" ] || continue
        target="$(readlink -f "$link" 2>/dev/null || true)"
        case "$target" in
            "$TARGET_DIR"/*)
                rm -f -- "$link" && { ok "ссылка $(basename "$link") снята"; removed=$((removed + 1)); }
                ;;
        esac
    done
    if [ "$removed" -eq 0 ]; then
        warn "ссылок VSM в /usr/local/bin не найдено"
    fi
}

# ----------------------------------------------------------------------
# 2. Свои таймеры
#
# vsm-heartbeat.timer и vsm-backup.timer ставит stacks/bots.sh вместе с ботами.
# Прежний uninstall.sh о них не знал: после «удаления» они оставались
# включёнными и раз в пять минут запускали отсутствующий скрипт — тихая ошибка,
# которую видно только в journalctl.
# ----------------------------------------------------------------------
remove_timers() {
    local unit removed=0
    for unit in vsm-heartbeat.timer vsm-heartbeat.service vsm-backup.timer vsm-backup.service; do
        [ -f "$UNIT_DIR/$unit" ] || continue
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        if ! rm -f -- "$UNIT_DIR/$unit"; then
            warn "не удалось удалить $UNIT_DIR/$unit"
            FAIL=1
            continue
        fi
        ok "юнит $unit снят"
        removed=$((removed + 1))
    done
    if [ "$removed" -gt 0 ]; then
        systemctl daemon-reload >/dev/null 2>&1 || warn "systemctl daemon-reload не выполнен"
    fi
}

# ----------------------------------------------------------------------
# 3. Боты
#
# Код ботов лежит ВНУТРИ репозитория, поэтому удалять их надо до него. Базы
# (история подключений по IP, список панелей) живут в bots/data и уходят вместе
# с каталогом — об этом сказано прямым текстом перед вопросом.
# ----------------------------------------------------------------------
remove_bots() {
    local unit found=0
    for unit in 3xui-telemt-bot telemt-bot 3xui-monitor; do
        [ -f "$UNIT_DIR/$unit.service" ] && found=1
    done
    [ "$found" -eq 1 ] || return 0

    say ""
    warn "Найдены службы Telegram-ботов. Вместе с репозиторием уйдут их базы:"
    warn "история подключений по IP и список панелей 3x-ui."
    if ! ask_word "УДАЛИТЬ" "Остановить и удалить ботов? Введите УДАЛИТЬ: "; then
        warn "боты оставлены; удаление репозитория ниже сломает их — код лежит в $TARGET_DIR/bots"
        return 0
    fi

    for unit in 3xui-telemt-bot telemt-bot 3xui-monitor; do
        if [ -f "$UNIT_DIR/$unit.service" ]; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || warn "не удалось остановить $unit"
            rm -f -- "$UNIT_DIR/$unit.service"
            ok "служба $unit снята"
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || warn "systemctl daemon-reload не выполнен"
    rm -f -- "$ETC_DIR/bots.conf"
    ok "настройки ботов удалены"
}

# ----------------------------------------------------------------------
# 4. Автозапуск в ~/.bashrc
#
# Только точные строки, которые дописал install.sh. Всё остальное, где
# встречается слово vsm, остаётся на месте — это может быть чужой алиас или
# PATH, и удалять его мы не вправе.
# ----------------------------------------------------------------------
clean_bashrc() {
    [ -f "$BASHRC" ] || { warn "$BASHRC не найден"; return 0; }
    if ! grep -qxF "$BASHRC_LINE" "$BASHRC" && ! grep -qxF "$BASHRC_LINE_OLD" "$BASHRC"; then
        warn "автозапуска VSM в $BASHRC нет"
        return 0
    fi

    local backup="$BASHRC.vsm-bak"
    cp -a -- "$BASHRC" "$backup" || { warn "не удалось сохранить копию $BASHRC"; FAIL=1; return 1; }

    # awk, а не grep -vxF: у файла, состоящего из одной строки автозапуска,
    # grep после фильтра не находит ни строки и возвращает 1 — то есть
    # штатное «удалили всё» выглядело бы как ошибка.
    # Временный файл рядом и mv, а не перенаправление в тот же файл: обрыв
    # записи не должен оставить .bashrc обрубком.
    local tmp
    tmp="$(mktemp "${BASHRC}.vsm.XXXXXX")" || { warn "не удалось создать временный файл"; FAIL=1; return 1; }
    if ! awk -v c="$BASHRC_COMMENT" -v l="$BASHRC_LINE" -v o="$BASHRC_LINE_OLD" \
             '$0 != c && $0 != l && $0 != o' "$BASHRC" > "$tmp"; then
        rm -f -- "$tmp"
        warn "не удалось переписать $BASHRC"
        FAIL=1
        return 1
    fi
    chmod --reference="$BASHRC" "$tmp" 2>/dev/null
    chown --reference="$BASHRC" "$tmp" 2>/dev/null
    if ! mv -f -- "$tmp" "$BASHRC"; then
        rm -f -- "$tmp"
        warn "не удалось заменить $BASHRC"
        FAIL=1
        return 1
    fi

    if grep -qxF "$BASHRC_LINE" "$BASHRC" || grep -qxF "$BASHRC_LINE_OLD" "$BASHRC"; then
        warn "строка автозапуска всё ещё в $BASHRC — проверьте вручную"
        FAIL=1
        return 1
    fi
    ok "автозапуск убран из $BASHRC (копия: $backup)"
}

# ----------------------------------------------------------------------
# 5. Каталог репозитория
# ----------------------------------------------------------------------
remove_repo() {
    [ -d "$TARGET_DIR" ] || { warn "каталог $TARGET_DIR уже отсутствует"; return 0; }
    say ""
    warn "Каталог $TARGET_DIR со всеми скриптами, ботами и их данными будет удалён."
    if ! ask_word "УДАЛИТЬ" "Удалить $TARGET_DIR? Введите УДАЛИТЬ: "; then
        warn "каталог сохранён"
        return 0
    fi
    rm -rf -- "$TARGET_DIR"
    # Факт, а не код возврата: rm может «успешно» не удалить часть файлов.
    if [ -e "$TARGET_DIR" ]; then
        warn "каталог $TARGET_DIR остался — удаление не завершено"
        FAIL=1
        return 1
    fi
    ok "каталог $TARGET_DIR удалён"
}

# ----------------------------------------------------------------------
# 6. Секреты и копии — отдельным вопросом
# ----------------------------------------------------------------------
purge_configs() {
    [ -d "$ETC_DIR" ] || [ -d "$BACKUP_DIR" ] || return 0
    say ""
    warn "В $ETC_DIR лежат пароли панелей и TELEMT_SECRET, в $BACKUP_DIR — их суточные копии."
    warn "Потеряв их, вы не восстановите доступ к панели и ссылки клиентов."
    if ! ask_word "ДА" "Удалить секреты и копии? Введите ДА: "; then
        warn "секреты и копии сохранены"
        return 0
    fi
    local d
    for d in "$ETC_DIR" "$BACKUP_DIR" "$MAP_DIR"; do
        [ -e "$d" ] || continue
        rm -rf -- "$d"
        if [ -e "$d" ]; then
            warn "$d остался — удаление не завершено"
            FAIL=1
        else
            ok "$d удалён"
        fi
    done
}

# ----------------------------------------------------------------------
say ""
say "${YELLOW}>>> Удаление VSM${NC}"
warn "Блоки nginx, правила UFW, fail2ban и сертификаты этим скриптом НЕ снимаются."
warn "Если стек ещё нужен до сноса сервера — сначала снимите его пунктами меню."
say ""

remove_links
remove_timers
remove_bots
clean_bashrc
remove_repo
purge_configs

say ""
say "${GREEN}======================================================${NC}"
if [ "$FAIL" -eq 0 ]; then
    say "${GREEN}Удаление завершено.${NC}"
else
    say "${RED}Удаление завершено С ЗАМЕЧАНИЯМИ — смотрите строки с «!» выше.${NC}"
fi
say "${YELLOW}Проверить, что осталось:${NC}"
say "  systemctl list-timers --all | grep vsm"
say "  ls -la /etc/vsm /var/backups/vsm 2>/dev/null"
say "${GREEN}======================================================${NC}"
exit "$FAIL"
