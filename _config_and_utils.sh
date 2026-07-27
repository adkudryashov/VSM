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
# УСТАНОВКА ПАКЕТОВ И ЗАПУСК ВНЕШНИХ СКРИПТОВ
# ----------------------------------------------------------------------

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
