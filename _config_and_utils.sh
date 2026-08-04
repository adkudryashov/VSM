#!/bin/bash

# ======================================================================
# ОБЩИЕ ПЕРЕМЕННЫЕ И ФУНКЦИИ ДЛЯ ВСЕХ СКРИПТОВ
# ======================================================================

# Числа считаем и печатаем с точкой независимо от локали системы.
# При LANG=ru_RU.UTF-8 разделителем становится запятая: awk выдаёт "1.02966",
# printf такое значение уже не принимает ("invalid number"), а если и напечатает,
# то как "1,0" — и bc спотыкается о запятую. Отсюда были ошибки при выводе
# объёма памяти на главном экране. LC_NUMERIC=C приводит awk, printf и bc
# к одному разделителю. На язык сообщений и формат дат не влияет.
export LC_NUMERIC=C

# Цвета ANSI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Определите имена и пути
SCANER_PATH="/root/RealiTLScanner-linux-64"
XUI_SERVICE="x-ui"

# --- ОБЩИЕ УТИЛИТЫ ---

# 1. Проверка статуса сервиса
function get_service_status() {
    # Получаем статус и обрезаем пробельные символы (включая \n) для безопасного сравнения
    sudo systemctl is-active "$1" 2>/dev/null | tr -d '[:space:]'
}

# 2. Вспомогательное меню для старта/стопа сервисов
function manage_service_status_restart {
    SERVICE_NAME=$1
    
    echo -e "\n${CYAN}>>> Действия для службы $SERVICE_NAME${NC}"
    echo -e "  1) ℹ️   Статус ${GREEN}(status)${NC}"
    echo -e "  2) ▶️   Запустить ${GREEN}(start)${NC}"
    echo -e "  3) ⏹️   Остановить ${RED}(stop)${NC}"
    echo -e "  4) 🔄  Перезапустить ${YELLOW}(restart)${NC}"
    echo -e "  5) 📄  Посмотреть логи в реальном времени ${CYAN}(logs)${NC}"
    echo -e "  X) 🔙  Назад"
    
    read -p "Ваш выбор [1-5, X]: " action
    
    case $action in
        1) 
            echo -e "${BLUE}------------------------------------------------------${NC}"
            sudo systemctl status $SERVICE_NAME --no-pager 
            ;;
        2) sudo systemctl start $SERVICE_NAME && echo -e "${GREEN}✅ Запущено!${NC}" ;;
        3) sudo systemctl stop $SERVICE_NAME && echo -e "${RED}🛑 Остановлено!${NC}" ;;
        4) sudo systemctl restart $SERVICE_NAME && echo -e "${YELLOW}🔄 Перезапущено!${NC}" ;;
        5) 
            echo -e "${YELLOW}ℹ️  Открываю журнал (последние 50 строк + новые события).${NC}"
            echo -e "${GREEN}ℹ️  Для ВЫХОДА обратно в меню нажмите Ctrl+C.${NC}"
            sleep 2
            sudo journalctl -u $SERVICE_NAME -n 50 -f
            ;;
        [Xx]) return ;;
        *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
    esac
    
    echo -e "${BLUE}------------------------------------------------------${NC}"
    read -p "Нажмите Enter для возврата в меню..."
}
# 3. Получение кода статуса ядра IPv6
function get_ipv6_status_code() {
    cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
    if [ $? -ne 0 ]; then
        echo 0 
    fi
}

# 4. Получение публичного IPv6-адреса
function get_public_ipv6 {
    local status_code=$(get_ipv6_status_code)
    
    if [ "$status_code" -eq 1 ]; then
        echo -e "${RED}Отключен${NC}"
        return
    fi
    
    # Способ 1: Получаем реальный внешний IP через API (самый надежный)
    IP_ADDR=$(curl -s -6 --max-time 2 ifconfig.me || curl -s -6 --max-time 2 api6.ipify.org)
    
    # Способ 2: Если API недоступен, парсим систему (игнорируем локальные fe80 и fd)
    if [[ -z "$IP_ADDR" ]]; then
        IP_ADDR=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d '/' -f 1 | grep -v -i "^fe80" | grep -v -i "^fd" | head -n 1)
    fi
    
    if [[ -z "$IP_ADDR" ]]; then
        echo -e "${YELLOW}Включен, адрес не назначен${NC}"
    else
        echo -e "${GREEN}$IP_ADDR${NC}"
    fi
}
# ----------------------------------------------------------------------
# АДРЕСА ПАНЕЛЕЙ ДЛЯ ШАПОК МЕНЮ
# ----------------------------------------------------------------------
# Обе функции печатают адрес или НИЧЕГО. Пустой вывод — штатный случай (панель
# не установлена, стек не настроен), и вызывающий просто не рисует строку.
# Сети не касаются: только локальные файлы и один быстрый вызов x-ui.

STACK_CONF_FILE="${STACK_CONF_FILE:-/etc/vsm/telemt.conf}"

# Обезвреживание значения перед выводом.
#
# Домены вводит человек (ask_domains формат не проверяет), путь панели приходит
# от самой 3x-ui. Оба попадают в echo -e, который разворачивает управляющие
# последовательности. Вырезаем управляющие символы и обратный слэш: команду
# так не выполнить, но нарисовать что попало в терминале администратора —
# запросто, причём при КАЖДОЙ отрисовке меню, потому что значение хранится.
function _addr_clean {
    printf '%s' "$1" | tr -d '\000-\037\177\\'
}

# То же для секретов, но БЕЗ вырезания обратного слэша: он законный символ
# пароля, и молча выброшенный он превратил бы показанный пароль в неверный —
# худший исход, чем любой мусор на экране. Поэтому секреты печатаются через
# printf с %s (аргумент не разбирается на escape-последовательности), а не
# через echo -e, и убрать достаточно только управляющие символы.
function _secret_clean {
    printf '%s' "$1" | tr -d '\000-\037\177'
}

# Домен панели 3x-ui.
#
# Основной источник — конфиг стека. Запасной нужен тем, у кого панель есть, а
# telemt не ставили: тогда конфига нет вовсе.
#
# У запасного пути жёсткое правило: подходящий vhost должен быть РОВНО ОДИН.
# Раньше брался первый попавшийся, и любой посторонний однодоменный конфиг в
# sites-enabled (добавленный руками, оставленный certbot) молча выдавался за
# адрес панели. Показать чужой домен хуже, чем не показать ничего: строка
# выглядит достоверной, а ведёт не туда.
function panel_domain {
    local d="" f names found=""
    if [ -f "$STACK_CONF_FILE" ]; then
        d=$(grep -m1 -oP '^DOMAIN_PANEL=\K.*' "$STACK_CONF_FILE" 2>/dev/null | tr -d "\"'")
    fi
    if [ -z "$d" ]; then
        for f in /etc/nginx/sites-enabled/*; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in 80.conf|00-maps.conf|*maps*) continue ;; esac
            names=$(grep -m1 -oP '^\s*server_name\s+\K[^;]+' "$f" 2>/dev/null | tr -s ' ')
            # Несколько имён в одном vhost — не понять, какое из них панель.
            [ "$(echo "$names" | wc -w)" = "1" ] || continue
            # Второй кандидат означает, что уверенности нет: сдаёмся молча.
            [ -n "$found" ] && { found=""; break; }
            found="$names"
        done
        d="$found"
    fi
    _addr_clean "$d"
}

# Полный адрес веб-панели 3x-ui: домен + собственный путь панели + panel/.
#
# Путь (webBasePath) у 3x-ui случайный, угадать его нельзя — спрашиваем саму
# панель. Вызов дешёвый (около 70 мс), поэтому годится и для шапки, которая
# перерисовывается при каждом возврате в меню.
function xui_panel_url {
    local bin=/usr/local/x-ui/x-ui domain path
    [ -x "$bin" ] || return 0
    domain=$(panel_domain)
    [ -n "$domain" ] || return 0
    # timeout обязателен: это единственный внешний процесс в шапке, а шапка
    # перерисовывается при каждом возврате в меню. Панель держит своё состояние
    # в sqlite, который открыт и работающей службой; заблокируйся он — меню
    # зависало бы намертво при каждой отрисовке. Не ответила за 2 с — считаем,
    # что адреса нет, и просто не рисуем строку.
    path=$(timeout 2 "$bin" setting -show true 2>/dev/null | grep -m1 -oP '^\s*webBasePath:\s*\K\S+')
    path=$(_addr_clean "$path")
    [ -n "$path" ] || return 0
    # Путь у панели может прийти и без крайних слэшей — приводим к /путь/.
    [ "${path#/}" = "$path" ] && path="/$path"
    [ "${path%/}" = "$path" ] && path="$path/"
    printf 'https://%s%spanel/' "$domain" "$path"
}

# Адрес telemt_panel. Живёт на домене REALITY и своём порту.
function telemt_panel_url {
    local d p
    [ -f "$STACK_CONF_FILE" ] || return 0
    d=$(_addr_clean "$(grep -m1 -oP '^DOMAIN_REALITY=\K.*' "$STACK_CONF_FILE" 2>/dev/null | tr -d "\"'")")
    # Порт — только цифры: он идёт в адрес, и мусору там взяться неоткуда.
    p=$(grep -m1 -oP '^PANEL_PORT=\K.*' "$STACK_CONF_FILE" 2>/dev/null | tr -dc '0-9')
    [ -n "$d" ] && [ -n "$p" ] || return 0
    printf 'https://%s:%s' "$d" "$p"
}

# ----------------------------------------------------------------------
# УЧЁТНЫЕ ДАННЫЕ ПАНЕЛИ 3x-ui
# ----------------------------------------------------------------------
# Прочитать логин и пароль панели с сервера НЕЛЬЗЯ: установщик 3x-ui-pro
# генерирует их случайно, печатает один раз и никуда не сохраняет, а сама
# панель держит пароль bcrypt-хэшем в своей sqlite. "x-ui setting -show true"
# отдаёт только SSL-статус, hasDefaultCredential, port и webBasePath.
# Поэтому VSM их не добывает, а ЗАПОМИНАЕТ: владелец вводит то, что уже
# действует, пункт меню кладёт значения сюда.
#
# Отдельный файл, а не /etc/vsm/telemt.conf: панель живёт и без стека telemt
# (ради этого случая у panel_domain есть запасной путь по vhost), и привязка
# к конфигу стека потеряла бы учётки на всех установках без telemt.
XUI_CONF_FILE="${XUI_CONF_FILE:-/etc/vsm/xui.conf}"

# Чтение — через source в подоболочке, а не grep. Файл пишется через printf %q,
# а пароль вводит человек: пробелы, $, кавычки в нём законны, и разбор вида
# grep -oP '^KEY=\K.*' | tr -d "\"'" вернул бы на таком значении мусор. Тот же
# приём применяется в telemt-stack.sh при переиспользовании старого пароля.
#
# _secret_clean обязателен: значение печатается при КАЖДОЙ отрисовке шапки, и
# управляющая последовательность в нём рисовала бы что попало в терминале.
function xui_admin_user {
    [ -f "$XUI_CONF_FILE" ] || return 0
    # shellcheck disable=SC1090
    _secret_clean "$(. "$XUI_CONF_FILE" 2>/dev/null; printf '%s' "${XUI_ADMIN_USER:-}")"
}

function xui_admin_pass {
    [ -f "$XUI_CONF_FILE" ] || return 0
    # shellcheck disable=SC1090
    _secret_clean "$(. "$XUI_CONF_FILE" 2>/dev/null; printf '%s' "${XUI_ADMIN_PASS:-}")"
}

# Запись. Каталог создаём сами: без стека telemt /etc/vsm на сервере может не
# существовать вовсе. Права как у конфига стека — 700 на каталог, 600 на файл.
# 0 — записано, 1 — не записано (причина в stderr).
function xui_credentials_save {
    local user="$1" pass="$2"
    if [ -z "$user" ] || [ -z "$pass" ]; then
        echo "нужны непустые логин и пароль" >&2
        return 1
    fi
    mkdir -p "$(dirname "$XUI_CONF_FILE")" || return 1
    chmod 700 "$(dirname "$XUI_CONF_FILE")"
    # umask до создания файла, а не chmod после: между открытием и chmod файл
    # существует с правами по умолчанию, и пароль в этот промежуток читается
    # кем угодно. chmod ниже оставлен для случая, когда файл уже был.
    ( umask 077; printf '# Создано VSM, не редактируй вручную.\n' > "$XUI_CONF_FILE" ) || return 1
    {
        printf 'XUI_ADMIN_USER=%q\n' "$user"
        printf 'XUI_ADMIN_PASS=%q\n' "$pass"
    } >> "$XUI_CONF_FILE" || return 1
    chmod 600 "$XUI_CONF_FILE"
    return 0
}

# ----------------------------------------------------------------------
# УСТАНОВКА ПАКЕТОВ И ЗАПУСК ВНЕШНИХ СКРИПТОВ
# ----------------------------------------------------------------------

# Ожидание освобождения блокировки dpkg.
#
# VSM по назначению запускают на ТОЛЬКО ЧТО созданном VPS, а там первые минуты
# работает unattended-upgrades и держит /var/lib/dpkg/lock-frontend. Любой apt
# в этот момент возвращает ошибку, и пакет молча не ставится. Поймано на
# чистой Ubuntu 24.04: из-за этого не установился acl, а следом умер весь
# установщик стека.
#
# Ждём молча только первые пару секунд: если блокировка держится дольше,
# пользователь должен понимать, почему всё встало.
function wait_for_apt {
    local waited=0 limit="${1:-300}"
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
                /var/lib/apt/lists/lock &>/dev/null; do
        if [ "$waited" -eq 0 ]; then
            echo -e "${YELLOW}    ожидаю освобождения apt (идёт установка обновлений)...${NC}"
        fi
        sleep 3
        waited=$((waited + 3))
        if [ "$waited" -ge "$limit" ]; then
            echo -e "${RED}    apt занят дольше ${limit} с — продолжаю без ожидания.${NC}"
            return 1
        fi
    done
    return 0
}

# Ставит пакеты и проверяет результат по факту.
#
# Раньше по всему меню повторялось `apt update && apt install -y ...`. Если в
# системе есть чужой битый репозиторий, `apt update` возвращает 100, `&&`
# обрывает цепочку, и пакеты молча не ставятся. `set -e` этого не ловит:
# первая команда AND-списка не последняя, её падение игнорируется. В итоге
# установка сообщала об успехе, а программы не было.
#
# Аргументы: имена пакетов. Если имя команды отличается от пакета,
# передавайте «пакет:команда» — проверяться будет команда.
function ensure_packages {
    local missing=() spec pkg cmd
    for spec in "$@"; do
        pkg="${spec%%:*}"; cmd="${spec##*:}"
        command -v "$cmd" &> /dev/null || missing+=("$pkg")
    done
    [ ${#missing[@]} -eq 0 ] && return 0

    echo -e "${YELLOW}>>> Требуется установить: ${missing[*]}${NC}"
    wait_for_apt
    # Обновление списков не через &&: его провал из-за чужого репозитория
    # не должен мешать установке пакетов из рабочих источников.
    sudo apt-get update -qq 2>/dev/null || \
        echo -e "${YELLOW}    (списки пакетов обновились с ошибками, продолжаю)${NC}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" || true

    local failed=()
    for spec in "$@"; do
        pkg="${spec%%:*}"; cmd="${spec##*:}"
        command -v "$cmd" &> /dev/null || failed+=("$pkg")
    done
    if [ ${#failed[@]} -gt 0 ]; then
        echo -e "${RED}❌ Не удалось установить: ${failed[*]}${NC}"
        echo -e "${YELLOW}   Смотрите вывод apt выше — там причина.${NC}"
        # Битый сторонний репозиторий — частая, но не единственная причина.
        # Называем его только если он действительно есть, иначе подсказка
        # уводила бы от настоящей проблемы (нехватка места, конфликт версий).
        if ! sudo apt-get update -qq >/dev/null 2>&1; then
            echo -e "${YELLOW}   Списки пакетов обновляются с ошибками. Проверьте"
            echo -e "   сторонние репозитории:${NC}"
            sudo apt-get update 2>&1 >/dev/null | grep -iE "^(E|W|Ошб|Err)" | head -3 | sed 's/^/     /'
        fi
        return 1
    fi
    echo -e "${GREEN}✓ Установлено: ${missing[*]}${NC}"
    return 0
}

# Скачивает внешний скрипт и запускает его.
#
# Замена для `bash <(curl ...)` и `curl ... | bash`: там при неудачной загрузке
# bash получает пустой ввод и выходит с нулём — сбой выглядел как успешное
# выполнение. Здесь загрузка отделена от запуска, и пустой ответ считается
# ошибкой.
#
# Аргументы: URL, затем аргументы самого скрипта.
function run_remote_script {
    local url="$1"; shift
    local tmp; tmp=$(mktemp /tmp/vsm-remote.XXXXXX.sh) || return 1

    if ! curl -fsSL --max-time 60 "$url" -o "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo -e "${RED}❌ Не удалось загрузить скрипт:${NC}"
        echo -e "${YELLOW}   $url${NC}"
        echo -e "${YELLOW}   Проверьте подключение к интернету и повторите.${NC}"
        return 1
    fi

    bash "$tmp" "$@"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

function check_and_install_qrencode {
    if ! command -v qrencode &> /dev/null; then
        echo -e "${YELLOW}💡 Утилита 'qrencode' не найдена.${NC}"
        read -p "$(echo -e "${YELLOW}Установить qrencode для отображения QR-кода? [Y/n]: ${NC}")" INSTALL_QR
        
        if [[ "$INSTALL_QR" =~ ^[Yy]$ || -z "$INSTALL_QR" ]]; then
            echo -e "${CYAN}>>> Запуск установки qrencode...${NC}"
            if command -v apt &> /dev/null; then
                sudo apt update -y > /dev/null 2>&1
                sudo apt install qrencode -y
            elif command -v yum &> /dev/null; then
                sudo yum install qrencode -y
            elif command -v dnf &> /dev/null; then
                sudo dnf install qrencode -y
            else
                echo -e "${RED}❌ Не удалось найти подходящий менеджер пакетов (apt, yum, dnf). Установите qrencode вручную.${NC}"
                return 1
            fi
            
            if command -v qrencode &> /dev/null; then
                echo -e "${GREEN}✅ qrencode успешно установлен.${NC}"
                return 0 # Установка успешна
            else
                echo -e "${RED}❌ Установка qrencode завершилась неудачей.${NC}"
                return 1
            fi
        fi
        return 1 # Пользователь отказался или установка не удалась
    fi
    return 0 # Уже установлен
}
