#!/bin/bash
source /usr/local/bin/_config_and_utils.sh

# Доустановка инструментов, на которых держатся пункты меню.
#
# Через ensure_packages, а не своим циклом: прежний вариант глушил вывод apt
# и печатал «✅ Утилиты установлены» безусловно, не проверив результат. При
# реальном отказе установки пользователь видел рапорт об успехе, а затем
# «command not found» из пункта меню — без единого намёка на причину.
# ensure_packages сверяет наличие команд ПОСЛЕ установки и показывает вывод apt.
function check_utils_deps {
    ensure_packages htop ncdu nethogs mtr || \
        echo -e "${YELLOW}   Пункты, которым нужны недостающие утилиты, работать не будут.${NC}"
}

function run_utils_menu {
    check_utils_deps
    
    while true; do
        clear 2>/dev/null
        ui_title "🧰  СИСТЕМНЫЕ УТИЛИТЫ"
        echo ""
        ui_section "НАБЛЮДЕНИЕ"
        ui_item "1" "📈" "Ресурсы"        "htop: процессы, память, нагрузка"
        ui_item "2" "💾" "Место на диске" "ncdu: что именно занимает место"
        ui_item "3" "🚦" "Сетевой трафик" "nethogs: кто и сколько передаёт"
        ui_item "4" "🔓" "Активные порты" "ss: кто слушает и откуда подключён"
        echo ""
        ui_section "СЕТЬ"
        ui_item "5" "🌍" "Внешний адрес"  "IPv4 и IPv6 сервера снаружи"
        ui_item "6" "📡" "Пинг и маршрут" "ping и mtr до произвольного узла"
        ui_item "7" "🔎" "Привязка домена" "Смотрит ли домен на этот сервер"
        echo ""
        ui_section "ОБСЛУЖИВАНИЕ"
        ui_item "8" "🧹" "Очистка"        "Кэш пакетов, журналы, временные файлы"
        echo ""
        ui_danger_item "9" "Завершить процесс" "kill: снимает выбранный процесс"
        ui_item "X" "🔙" "Назад"
        echo ""
        
        read -p "Ваш выбор: " choice
        case $choice in
            1)
                htop
                ;;
            2)
                echo -e "\n${CYAN}--- Параметры сканирования (ncdu) ---${NC}"
                echo -e "1) Весь диск (/)"
                echo -e "2) Системные логи (/var/log)"
                echo -e "3) Текущая папка ($(pwd))"
                echo -e "4) Ввести путь вручную"
                read -p "Выбор: " ncdu_opt
                case $ncdu_opt in
                    1) ncdu / ;;
                    2) ncdu /var/log ;;
                    3) ncdu . ;;
                    4) read -p "Введите путь: " custom_path; if [ -d "$custom_path" ]; then ncdu "$custom_path"; else echo -e "${RED}Папка не найдена.${NC}"; sleep 2; fi ;;
                    *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
                esac
                ;;
            3)
                echo -e "\n${CYAN}--- Доступные интерфейсы ---${NC}"
                ip -br link show | awk '{print $1}' | grep -v "^lo$" | awk '{print NR ") " $1}'
                echo -e "A) Все сразу"
                read -p "Выберите интерфейс: " net_opt
                if [[ "$net_opt" =~ ^[Aa]$ ]]; then
                    nethogs
                elif [[ "$net_opt" =~ ^[0-9]+$ ]]; then
                    iface=$(ip -br link show | awk '{print $1}' | grep -v "^lo$" | sed -n "${net_opt}p")
                    if [ -n "$iface" ]; then
                        nethogs "$iface"
                    else
                        echo -e "${RED}Неверный выбор.${NC}"; sleep 1
                    fi
                else
                    echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1
                fi
                ;;
            5)
                echo -e "\n${CYAN}--- Проверка IP ---${NC}"
                echo -e "${YELLOW}IPv4:${NC} $(curl -4 -s -m 4 ifconfig.me || echo 'Недоступен')"
                echo -e "${YELLOW}IPv6:${NC} $(curl -6 -s -m 4 ifconfig.me || echo 'Недоступен')"
                read -p "Нажмите Enter..."
                ;;
            6)
                echo -e "\n${CYAN}--- Пинг и Трассировка ---${NC}"
                read -p "Введите IP или домен (например, 8.8.8.8 или google.com): " target
                if [ -z "$target" ]; then continue; fi
                echo -e "1) Обычный ping (4 пакета)"
                echo -e "2) Непрерывный ping (Ctrl+C для выхода)"
                echo -e "3) Трассировка MTR (в реальном времени)"
                read -p "Выбор: " ping_opt
                case $ping_opt in
                    1) ping -c 4 "$target" ;;
                    2) ping "$target" ;;
                    3) mtr "$target" ;;
                    *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
                esac
                read -p "Нажмите Enter..."
                ;;
            4)
                echo -e "\n${CYAN}--- Активные порты (ss) ---${NC}"
                echo -e "1) Только TCP-порты"
                echo -e "2) Только UDP-порты"
                echo -e "3) Все активные порты (TCP + UDP)"
                read -p "Выбор: " port_opt
                echo ""
                case $port_opt in
                    1) ss -tlpn ;;
                    2) ss -ulpn ;;
                    3) ss -tulpn ;;
                    *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
                esac
                echo ""
                read -p "Нажмите Enter..."
                ;;
            9)
                echo -e "\n${CYAN}--- Завершение процессов ---${NC}"
                echo -e "1) Найти процесс по имени (узнать PID)"
                echo -e "2) Убить по точному PID (kill -9)"
                echo -e "3) Убить все процессы по имени (killall -9)"
                read -p "Выбор: " kill_opt
                case $kill_opt in
                    1)
                        read -p "Введите часть имени: " s_name
                        echo -e "${YELLOW}Найденные процессы:${NC}"
                        ps aux | grep -i "$s_name" | grep -v "grep" | awk '{print "PID: " $2 " | Владелец: " $1 " | Команда: " $11}'
                        ;;
                    2)
                        read -p "Введите PID: " k_pid
                        if kill -9 "$k_pid" 2>/dev/null; then echo -e "${GREEN}Процесс $k_pid жестоко убит.${NC}"; else echo -e "${RED}Ошибка: Процесс не найден или нет прав.${NC}"; fi
                        ;;
                    3)
                        read -p "Введите точное имя (например, nginx): " k_name
                        if killall -9 "$k_name" 2>/dev/null; then echo -e "${GREEN}Процессы $k_name убиты.${NC}"; else echo -e "${RED}Процесс не найден.${NC}"; fi
                        ;;
                    *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
                esac
                read -p "Нажмите Enter..."
                ;;
            8)
                echo -e "\n${CYAN}--- Очистка системы ---${NC}"
                echo -e "1) Очистить кэш скачанных пакетов (apt clean)"
                echo -e "2) Удалить ненужные зависимости (apt autoremove)"
                echo -e "3) Очистить системные логи (оставить за последние 3 дня)"
                echo -e "4) 🚀 Выполнить всё сразу"
                read -p "Выбор: " clean_opt
                case $clean_opt in
                    1) apt-get clean; echo -e "${GREEN}Кэш APT очищен.${NC}" ;;
                    2) DEBIAN_FRONTEND=noninteractive apt-get autoremove -y; echo -e "${GREEN}Зависимости очищены.${NC}" ;;
                    3) journalctl --vacuum-time=3d; echo -e "${GREEN}Старые логи удалены.${NC}" ;;
                    4) 
                       apt-get clean
                       DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
                       journalctl --vacuum-time=3d
                       echo -e "${GREEN}Полная очистка завершена! Место освобождено.${NC}"
                       ;;
                    *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
                esac
                read -p "Нажмите Enter..."
                ;;
            7)
                echo -e "\n${CYAN}--- Проверка привязки домена ---${NC}"
                read -p "Введите домен (например, sub.domain.com): " check_domain
                if [ -n "$check_domain" ]; then
                    echo -e "\n${YELLOW}Проверка DNS-записей...${NC}"
                    domain_ip=$(getent hosts "$check_domain" | awk '{ print $1 }' | head -n 1)
                    server_ip=$(curl -4 -s -m 4 ifconfig.me)
                    
                    if [ -z "$domain_ip" ]; then
                        echo -e "${RED}❌ Не удалось определить IP. Домен не существует или DNS еще не обновились (обычно занимает от 5 минут до 24 часов).${NC}"
                    else
                        echo -e "IP этого сервера: ${GREEN}$server_ip${NC}"
                        echo -e "IP домена:        ${YELLOW}$domain_ip${NC}\n"
                        
                        if [ "$domain_ip" == "$server_ip" ]; then
                            echo -e "${GREEN}✅ Отлично! Домен успешно направлен на этот сервер.${NC}"
                        else
                            echo -e "${RED}❗ Внимание! IP не совпадают.${NC}"
                            echo -e "• Если вы используете проксирование Cloudflare (оранжевое облако) — это нормально."
                            echo -e "• Если нет — проверьте A-запись в настройках вашего регистратора."
                        fi
                    fi
                fi
                read -p "Нажмите Enter..."
                ;;
            [Xx])
                return
                ;;
            *) continue ;;
        esac
    done
}

run_utils_menu
