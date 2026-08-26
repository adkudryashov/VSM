#!/bin/bash
# Прерываемся на первой же ошибке: без этого падение apt или git оставляло
# симлинки на несуществующие файлы, а установка «завершалась успешно».
set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

trap 'echo -e "\n${RED}❌ Установка прервана на строке $LINENO. Ничего не доделано — исправьте причину и запустите install.sh заново.${NC}" >&2' ERR

echo -e "${YELLOW}>>> Начало установки VSM...${NC}"

# 1. Обновление системы и установка зависимостей
#
# Не через `apt update && apt install`: если в системе есть чужой битый
# репозиторий, `apt update` возвращает 100, `&&` обрывает цепочку и пакеты
# молча не ставятся. set -e это не ловит — первая команда AND-списка не
# последняя, её падение игнорируется. Установка при этом рапортовала об
# успехе, а, например, qrencode так и не появлялся.
#
# Здесь свои проверки, а не ensure_packages из lib/common.sh: этот
# скрипт запускают через curl до того, как репозиторий склонирован.
echo -e "${YELLOW}>>> Установка необходимых пакетов...${NC}"
# На только что созданном VPS первые минуты работает unattended-upgrades и
# держит блокировку dpkg. Без ожидания apt возвращает ошибку и пакеты молча не
# ставятся — а это самая первая команда, которую пользователь вообще запускает.
# Ждёт САМ apt, а не мы снаружи.
#
# ЗДЕСЬ БЫЛ ЦИКЛ НА fuser, И ОН НЕ РАБОТАЛ ВОВСЕ. `while fuser … &>/dev/null`
# на системе без psmisc падает с «command not found», условие сразу ложно, и
# тело цикла не выполняется ни разу — то есть ожидания нет, а выглядит так,
# будто оно есть. Поймано на чистой Ubuntu 26.04 (26.08.2026): fuser там не
# ставится по умолчанию, и защита, заведённая после реальной поломки
# установщика, молча отсутствовала.
#
# DPkg::Lock::Timeout умеет сам apt начиная с 1.9.11 (2019) — то есть на всех
# поддерживаемых нами системах, от 20.04. Он знает про свои замки больше любой
# внешней утилиты, ждёт их все и не требует лишнего пакета. Заводить
# зависимость ради того, чтобы подсмотреть за apt снаружи, было ошибкой.
APT_WAIT=(-o DPkg::Lock::Timeout=300)
echo -e "${YELLOW}    (если идут автообновления, apt подождёт их до 5 минут)${NC}"
apt-get "${APT_WAIT[@]}" update -qq 2>/dev/null || \
    echo -e "${YELLOW}    (списки пакетов обновились с ошибками, продолжаю)${NC}"
DEBIAN_FRONTEND=noninteractive apt-get "${APT_WAIT[@]}" install -y curl git bc jq ufw qrencode || true

MISSING=""
for c in curl git bc jq ufw qrencode; do
    command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
    echo -e "${RED}❌ Не установлены:$MISSING${NC}" >&2
    echo -e "${YELLOW}   Частая причина — битый сторонний репозиторий в"
    echo -e "   /etc/apt/sources.list.d/. Установите пакеты вручную и повторите.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Зависимости на месте${NC}"

# 2. Определяем рабочую директорию
TARGET_DIR="/root/VSM"
OLD_DIR="/root/VPS-main-menu"
OLD_CONF="/etc/server-menu"
NEW_CONF="/etc/vsm"

# 2.1 Переезд со старого имени (VPS-main-menu / server-menu -> VSM / vsm).
# Каталог репозитория прописан в юнитах ботов и в crontab, а /etc/server-menu
# хранит боевые конфиги с токенами — просто клонировать в новое место нельзя,
# иначе боты останутся указывать в никуда, а настройки потеряются.
migrate_from_old_name() {
    [ -d "$OLD_DIR" ] || [ -d "$OLD_CONF" ] || return 0
    echo -e "${YELLOW}>>> Обнаружена установка под прежним именем, переношу...${NC}"

    # Боты держат рабочий каталог открытым — останавливаем до переноса
    local units="3xui-telemt-bot telemt-bot 3xui-monitor"
    for u in $units; do
        [ -f "/etc/systemd/system/$u.service" ] && systemctl stop "$u" 2>/dev/null || true
    done

    if [ -d "$OLD_DIR" ] && [ ! -d "$TARGET_DIR" ]; then
        mv "$OLD_DIR" "$TARGET_DIR"
        echo -e "${GREEN}✓ $OLD_DIR → $TARGET_DIR${NC}"
    elif [ -d "$OLD_DIR" ] && [ -d "$TARGET_DIR" ]; then
        # Оба каталога сразу: перенести нельзя, а переписать юниты ниже —
        # значит увести ботов от их баз и venv. Молча продолжать тут опаснее,
        # чем остановиться: данные останутся в старом каталоге незамеченными.
        echo -e "${RED}❌ Существуют оба каталога: $OLD_DIR и $TARGET_DIR.${NC}" >&2
        echo -e "${YELLOW}   Автоматический перенос отменён, чтобы не потерять данные."
        echo -e "   В $OLD_DIR могут быть базы ботов, venv и .env."
        echo -e "   Перенесите нужное вручную, удалите лишний каталог и запустите заново.${NC}" >&2
        exit 1
    fi
    if [ -d "$OLD_CONF" ] && [ ! -d "$NEW_CONF" ]; then
        mv "$OLD_CONF" "$NEW_CONF"
        echo -e "${GREEN}✓ $OLD_CONF → $NEW_CONF${NC}"
    fi

    # Юниты ботов, crontab и автозапуск ссылаются на старые пути.
    # Проверки через if: при set -e конструкция «условие && команда»
    # обрывает скрипт, когда условие ложно.
    local changed=0
    for f in /etc/systemd/system/*.service; do
        [ -f "$f" ] || continue
        if grep -q "$OLD_DIR" "$f"; then
            sed -i "s|$OLD_DIR|$TARGET_DIR|g" "$f"; changed=1
            echo -e "${GREEN}✓ юнит $(basename "$f") обновлён${NC}"
        fi
    done
    if [ "$changed" -eq 1 ]; then systemctl daemon-reload; fi

    if crontab -l 2>/dev/null | grep -q "$OLD_DIR"; then
        crontab -l 2>/dev/null | sed "s|$OLD_DIR|$TARGET_DIR|g" | crontab -
        echo -e "${GREEN}✓ crontab обновлён${NC}"
    fi

    # Старые симлинки ведут в исчезнувший каталог
    for link in /usr/local/bin/*; do
        [ -L "$link" ] || continue
        case "$(readlink "$link")" in "$OLD_DIR"/*) rm -f "$link" ;; esac
    done
    rm -f /usr/local/bin/server-menu

    if grep -q "server-menu" ~/.bashrc 2>/dev/null; then
        sed -i 's/\bserver-menu\b/vsm/g' ~/.bashrc
        echo -e "${GREEN}✓ автозапуск в ~/.bashrc переведён на vsm${NC}"
    fi
    # Боты не запускаем здесь: код обновится ниже, поднимем их в самом конце
}
migrate_from_old_name

# 3. Клонирование или обновление репозитория
if [ -d "$TARGET_DIR/.git" ]; then
    echo -e "${YELLOW}>>> Репозиторий уже существует. Обновляем...${NC}"
    cd "$TARGET_DIR" || exit
    git fetch origin main
    git reset --hard origin/main
else
    echo -e "${YELLOW}>>> Клонирование репозитория...${NC}"
    rm -rf "$TARGET_DIR"
    git clone https://github.com/adkudryashov/VSM.git "$TARGET_DIR"
fi

# 4. Права на исполнение — по каталогам, а не маской по корню.
#
# В корне теперь лежат только install.sh, uninstall.sh и vsm; всё исполняемое
# разошлось по menus/, stacks/, tools/. Бит исполнения хранится в самом
# репозитории (git update-index --chmod=+x), так что chmod здесь — страховка на
# случай переноса каталога через архив или файловую систему без прав.
echo -e "${YELLOW}>>> Установка прав на исполнение...${NC}"
chmod +x "$TARGET_DIR/vsm" 2>/dev/null
for d in menus stacks tools checks; do
    [ -d "$TARGET_DIR/$d" ] || continue
    chmod +x "$TARGET_DIR/$d"/*.sh 2>/dev/null
done
# lib/ намеренно НЕ трогаем: эти файлы сорсятся, а не запускаются. Бит
# исполнения на них — приглашение запустить библиотеку напрямую.

# 5. Системная ссылка ровно одна: vsm.
#
# Раньше здесь была маска по корню репозитория, и в /usr/local/bin уезжало
# двадцать файлов: библиотеки, которые исполнять нельзя, установщики, которые
# вызывает меню, и — что хуже всего — checks/ui.sh с checks/accept.sh, то есть
# проверки разработчика, которым на боевом сервере делать нечего. Пользователю
# из всего этого нужна одна команда.
#
# Меню и установщики меню находят по своему расположению (lib/common.sh задаёт
# VSM_ROOT), поэтому в PATH им быть незачем.
echo -e "${YELLOW}>>> Создание системной ссылки vsm...${NC}"
ln -sf "$TARGET_DIR/vsm" /usr/local/bin/vsm

# 5б. Уборка за прежней раскладкой.
#
# Два прохода, и оба нужны. Первый снимает ссылки в каталог VSM: после переезда
# они все указывают в никуда, но полагаться на это нельзя — файл с тем же именем
# может однажды снова появиться, и тогда битым он не будет. Второй добирает всё
# остальное, что указывает в никуда: так когда-то осталась ссылка на
# censorcheck.sh, удалённый из репозитория, — поимённый список за реальностью
# не поспевал.
for link in /usr/local/bin/*; do
    [ -L "$link" ] || continue
    [ "$link" = "/usr/local/bin/vsm" ] && continue
    case "$(readlink "$link")" in
        "$TARGET_DIR"/*)
            rm -f "$link"
            echo -e "${YELLOW}✓ снята ссылка прежней раскладки $(basename "$link")${NC}"
            continue ;;
    esac
    if [ ! -e "$link" ]; then
        rm -f "$link"
        echo -e "${YELLOW}✓ снята битая ссылка $(basename "$link")${NC}"
    fi
done
# 7. Настройка автозапуска при входе в систему
echo -e "${YELLOW}>>> Настройка автозапуска меню...${NC}"
if ! grep -q "vsm" ~/.bashrc; then
    echo -e "\n# Автозапуск основного меню\nif [[ -t 0 ]]; then vsm; fi" >> ~/.bashrc
    echo -e "${GREEN}✓ Автозапуск добавлен в ~/.bashrc${NC}"
else
    echo -e "${YELLOW}! Автозапуск уже настроен${NC}"
fi
# 8. Поднимаем ботов, если они установлены. Код мог обновиться выше, а при
# переезде со старого имени они были остановлены — оставить их лежать нельзя.
for u in 3xui-telemt-bot telemt-bot 3xui-monitor; do
    [ -f "/etc/systemd/system/$u.service" ] || continue
    systemctl restart "$u" 2>/dev/null || true
    sleep 3
    # Сообщаем по факту, а не по факту вызова: раньше «✓ перезапущена»
    # печаталось даже когда служба не поднялась, и установка рапортовала
    # об успехе при молчащем боте.
    if [ "$(systemctl is-active "$u")" = "active" ]; then
        echo -e "${GREEN}✓ служба $u работает${NC}"
    else
        echo -e "${RED}✗ служба $u не поднялась — journalctl -u $u -n 20${NC}"
    fi
done

echo -e "${GREEN}======================================================"
echo -e "✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
echo -e "------------------------------------------------------"
echo -e "Добавлен пакет: ufw (не забудьте настроить правила)"
echo -e "Запуск меню: ${YELLOW}vsm${NC}"
echo -e "======================================================${NC}"
