#!/bin/bash
source /usr/local/bin/_config_and_utils.sh

# ----------------------------------------------------------------------
# УПРАВЛЕНИЕ CLOUDFLARE WARP
# ----------------------------------------------------------------------

function get_warp_status {
    if ! command -v warp-cli &> /dev/null; then
        echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"
    elif systemctl is-active --quiet warp-svc; then
        echo -e "${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e "${YELLOW}ОСТАНОВЛЕН${NC}"
    fi
}

function setup_warp_cron {
    while true; do
        clear 2>/dev/null
        echo -e "${CYAN}--- 🔄 НАСТРОЙКА АВТОПЕРЕЗАПУСКА WARP --------------------${NC}"
        echo -e "    Текущий статус: $(get_warp_cron_status)"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        echo -e "1) 🌙  Каждую ночь (в 03:00)"
        echo -e "2) 📅  Раз в неделю (в Воскресенье ночью)"
        echo -e "3) ⏳  Каждые 12 часов"
        echo -e "4) 🚫  Отключить автоперезапуск"
        echo -e "5) 📝   Задать свой график (формат Cron)"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        read -p "Выбор: " cron_choice
        case $cron_choice in
            1) cron_rule="0 3 * * * systemctl restart warp-svc >/dev/null 2>&1" ;;
            2) cron_rule="0 3 * * 0 systemctl restart warp-svc >/dev/null 2>&1" ;;
            3) cron_rule="0 */12 * * * systemctl restart warp-svc >/dev/null 2>&1" ;;
            4) crontab -l 2>/dev/null | grep -v "warp-svc" | crontab -; echo -e "${GREEN}✅ Отключено.${NC}"; sleep 1; return ;;
            5)
                echo -e "\n${CYAN}╭─── Справка по формату Cron ──────────────────────╮${NC}"
                echo -e "${CYAN}│${NC}  ${YELLOW}* * * * *${NC}                                       ${CYAN}│${NC}"
                echo -e "${CYAN}│${NC}  ${YELLOW}│ │ │ │ │${NC}                                       ${CYAN}│${NC}"
                echo -e "${CYAN}│${NC}  ${YELLOW}│ │ │ │ └${NC} День недели (0-7, где 0 или 7 это Вс) ${CYAN}│${NC}"
                echo -e "${CYAN}│${NC}  ${YELLOW}│ │ │ └────${NC} Месяц (1-12)                        ${CYAN}│${NC}"
                echo -e "${CYAN}│${NC}  ${YELLOW}│ │ └──────${NC} День месяца (1-31)                  ${CYAN}│${NC}"
                echo -e "${CYAN}│${NC}  ${YELLOW}│ └────────${NC} Часы (0-23)                         ${CYAN}│${NC}"
                echo -e "${CYAN}│${NC}  ${YELLOW}└──────────${NC} Минуты (0-59)                       ${CYAN}│${NC}"
                echo -e "${CYAN}╰──────────────────────────────────────────────────╯${NC}"
                echo -e "${YELLOW}Доступные форматы: ${GREEN}*${NC} (все), ${GREEN}1-5${NC} (диапазон), ${GREEN}6,0${NC} (список), ${GREEN}*/10${NC} (шаг)"
                echo -e "${YELLOW}Популярные примеры:${NC}"
                echo -e "  ${GREEN}0 5 * * *${NC}    (Каждый день ровно в 05:00)"
                echo -e "  ${GREEN}*/30 * * * *${NC} (Каждые 30 минут)"
                echo -e "  ${GREEN}0 2 * * 1-5${NC}  (По будням в 02:00)"
                echo -e "  ${GREEN}0 12 * * 6,0${NC} (По выходным в 12:00)"
                echo ""
                read -p "Ваш график (5 значений через пробел): " custom_cron
                
                # Простая проверка: должно быть ровно 5 "слов" (значений)
                if [[ $(echo "$custom_cron" | wc -w) -eq 5 ]]; then
                    cron_rule="$custom_cron systemctl restart warp-svc >/dev/null 2>&1"
                else
                    echo -e "${RED}❌ Ошибка! Нужно ввести ровно 5 значений (например: 0 4 * * *).${NC}"
                    sleep 2
                    continue
                fi
                ;;
            [Xx]) return ;;
            *) continue ;;
        esac
        
        # Применяем правило
        crontab -l 2>/dev/null | grep -v "warp-svc" | crontab -
        (crontab -l 2>/dev/null; echo "$cron_rule") | crontab -
        echo -e "${GREEN}✅ Расписание обновлено!${NC}"; sleep 1; return
    done
}

function get_warp_port {
    if command -v warp-cli &> /dev/null; then
        local port=$(ss -nltp | grep -w 'warp-svc' | awk '{print $4}' | rev | cut -d: -f1 | rev | head -n 1)
        if [ -n "$port" ]; then
            echo "$port"
        else
            echo "Не определен (служба стоп или нет сети)"
        fi
    else
        echo "-"
    fi
}

function get_warp_cron_status {
    local cron_rule=$(crontab -l 2>/dev/null | grep -w "warp-svc")
    
    if [ -z "$cron_rule" ]; then
        echo -e "${RED}ВЫКЛЮЧЕН${NC}"
        return
    fi

    local m=$(echo "$cron_rule" | awk '{print $1}')
    local h=$(echo "$cron_rule" | awk '{print $2}')
    local d=$(echo "$cron_rule" | awk '{print $3}')
    local mon=$(echo "$cron_rule" | awk '{print $4}')
    local dow=$(echo "$cron_rule" | awk '{print $5}')

    # 0. Ежеминутно (* * * * * или * * * * 0-7)
    if [[ "$m" == "*" && "$h" == "*" && "$d" == "*" && "$mon" == "*" && ("$dow" == "*" || "$dow" == "0-7") ]]; then
        echo -e "${GREEN}Каждую минуту (Осторожно!)${NC}"

    # 1. Ежедневно в определенное время (0 2 * * * или 0 2 * * 0-7)
    elif [[ "$d" == "*" && "$mon" == "*" && ("$dow" == "*" || "$dow" == "0-7") && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]]; then
        printf -v formatted_time "%02d:%02d" "$h" "$m"
        echo -e "${GREEN}Ежедневно в $formatted_time${NC}"

    # 2. По будням (например, 0 2 * * 1-5)
    elif [[ "$d" == "*" && "$mon" == "*" && "$dow" == "1-5" && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]]; then
        printf -v formatted_time "%02d:%02d" "$h" "$m"
        echo -e "${GREEN}По будням в $formatted_time${NC}"

    # 3. По выходным (например, 0 2 * * 6,0 или 6,7)
    elif [[ "$d" == "*" && "$mon" == "*" && ("$dow" == "6,0" || "$dow" == "0,6" || "$dow" == "6,7") && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]]; then
        printf -v formatted_time "%02d:%02d" "$h" "$m"
        echo -e "${GREEN}По выходным в $formatted_time${NC}"

    # 4. Раз в неделю (конкретный день, например 0 3 * * 0)
    elif [[ "$d" == "*" && "$mon" == "*" && "$dow" =~ ^[0-7]$ && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]]; then
        printf -v formatted_time "%02d:%02d" "$h" "$m"
        local days=("Вс" "Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс")
        echo -e "${GREEN}Раз в неделю (${days[$dow]} $formatted_time)${NC}"

    # 5. Ежемесячно (например, 0 5 15 * * -> 15-го числа)
    elif [[ "$d" =~ ^[0-9]+$ && "$mon" == "*" && "$dow" == "*" && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]]; then
        printf -v formatted_time "%02d:%02d" "$h" "$m"
        echo -e "${GREEN}Каждое $d-е число в $formatted_time${NC}"

    # 6. Точная дата / Ежегодно (например, 23 4 21 3 * -> 21 Марта в 04:23)
    elif [[ "$d" =~ ^[0-9]+$ && "$mon" =~ ^[0-9]+$ && "$dow" == "*" && "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]]; then
        printf -v formatted_time "%02d:%02d" "$h" "$m"
        local months=("" "Января" "Февраля" "Марта" "Апреля" "Мая" "Июня" "Июля" "Августа" "Сентября" "Октября" "Ноября" "Декабря")
        echo -e "${GREEN}Ежегодно $d ${months[$mon]} в $formatted_time${NC}"

    # 7. Каждые X часов (например, 0 */12 * * *)
    elif [[ "$h" == */* && "$m" =~ ^[0-9]+$ && "$d" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        local hours=${h#*/}
        echo -e "${GREEN}Каждые $hours ч.${NC}"

    # 8. Каждые X минут (например, */30 * * * *)
    elif [[ "$m" == */* && "$h" == "*" && "$d" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        local mins=${m#*/}
        echo -e "${GREEN}Каждые $mins мин.${NC}"

    # 9. Если кастомный (совсем сложная комбинация)
    else
        echo -e "${GREEN}Свой график ($m $h $d $mon $dow)${NC}"
    fi
}

function run_warp_menu {
    while true; do
        clear 2>/dev/null
        ui_title "📦  CLOUDFLARE WARP"
        echo ""
        echo -e "   ${C_NAME}$(ui_pad '🚥  Статус' 20)${NC}$(get_warp_status)"
        ui_kv '🔌  Порт SOCKS5'   "$(get_warp_port)" 20
        echo -e "   ${C_NAME}$(ui_pad '🔄  Авторестарт' 20)${NC}$(get_warp_cron_status)"
        echo ""
        ui_section "CLOUDFLARE WARP"
        ui_item "1" "🚀" "Установить"      "Клиент WARP в режиме SOCKS5"
        ui_item "2" "🔧" "Порт прокси"     "Сменить порт локального SOCKS5"
        ui_item "3" "🔄" "Автоперезапуск"  "Расписание перезапуска службы"
        ui_item "4" "🚥" "Служба"          "Старт, стоп, состояние"
        ui_item "5" "📄" "Журнал"          "Записи службы в реальном времени"
        echo ""
        ui_danger_item "6" "Удалить WARP"  "Клиент, настройки и расписание"
        ui_item "X" "🔙" "Назад"
        echo ""
        
        read -p "Ваш выбор: " choice
        case $choice in
            1)
                if command -v warp-cli &> /dev/null; then
                    echo -e "${YELLOW}Уже установлен.${NC}"; read -p "Enter..."; continue
                fi
                echo -e "${CYAN}>>> Установка...${NC}"
                curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >/dev/null 2>&1
                echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
                
                # Через ensure_packages: прежний `apt-get update && install`
                # не ставил пакет, если обновление списков падало из-за любого
                # другого битого репозитория в системе — хотя репозиторий
                # Cloudflare, добавленный выше, при этом был рабочим.
                if ensure_packages "cloudflare-warp:warp-cli"; then
                    echo -e "${YELLOW}Запуск службы и ожидание готовности WARP...${NC}"
                    systemctl enable --now warp-svc >/dev/null 2>&1
                    
                    for i in {1..10}; do
                        if warp-cli --accept-tos status >/dev/null 2>&1; then
                            break
                        fi
                        sleep 2
                    done
                    
                    warp-cli --accept-tos registration new >/dev/null 2>&1
                    warp-cli --accept-tos mode proxy >/dev/null 2>&1
                    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
                    warp-cli --accept-tos connect >/dev/null 2>&1
                    
                    crontab -l 2>/dev/null | grep -v "warp-svc" | crontab -
                    (crontab -l 2>/dev/null; echo "0 3 * * * systemctl restart warp-svc >/dev/null 2>&1") | crontab -
                    
                    hash -r 
                    echo -e "${GREEN}✅ Готово! Режим прокси (порт 40000) включен.${NC}"
                    echo -e "${YELLOW}(Внимание: На серверах в РФ WARP может не подключиться из-за блокировок РКН)${NC}"
                else
                    echo -e "${RED}❌ Ошибка! APT заблокирован.${NC}"
                fi
                read -p "Нажмите Enter..." ;;
            2)
                # Проверка установки — соседние пункты её делают, этот забыл.
                #
                # На сервере без WARP пункт вываливал сырое «warp-cli: command
                # not found» и следом бодро печатал «✅ Порт: …», потому что
                # успех не проверялся. Тот самый рапорт об успехе поверх
                # ничего не сделанного. Найдено приёмкой обработчиков.
                if ! command -v warp-cli &> /dev/null; then
                    echo -e "${RED}❌ WARP не установлен — менять порт нечему.${NC}"
                    echo -e "${YELLOW}   Сначала пункт 1«Установить».${NC}"
                    read -p "Нажмите Enter..."; continue
                fi
                read -p "Новый порт: " new_port
                if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
                    echo -e "${RED}❌ Порт должен быть числом от 1024 до 65535.${NC}"
                    read -p "Нажмите Enter..."; continue
                fi
                # Успех проверяем, а не предполагаем: warp-cli отвергает порт
                # молча чаще, чем хотелось бы.
                if warp-cli --accept-tos proxy port "$new_port" && systemctl restart warp-svc; then
                    echo -e "${GREEN}✅ Порт: $new_port${NC}"
                else
                    echo -e "${RED}❌ Не удалось задать порт ${new_port}.${NC}"
                fi
                read -p "Нажмите Enter..." ;;
            3) setup_warp_cron ;;
            4)
                if systemctl is-active --quiet warp-svc; then
                    systemctl stop warp-svc
                else
                    systemctl start warp-svc
                fi ;;
            5)
                echo -e "${CYAN}>>> Просмотр логов warp-svc (Ctrl+C для выхода)...${NC}"
                sleep 1
                trap ' ' INT
                journalctl -eu warp-svc -f
                trap - INT
                ;;
            6)
                if ! command -v warp-cli &> /dev/null; then
                    echo -e "${RED}WARP не установлен.${NC}"; read -p "Enter..."; continue
                fi
                read -p "❗  Вы уверены, что хотите ПОЛНОСТЬЮ удалить WARP? (y/N): " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Остановка и очистка...${NC}"
                    warp-cli --accept-tos disconnect >/dev/null 2>&1
                    systemctl disable --now warp-svc >/dev/null 2>&1
                    
                    if DEBIAN_FRONTEND=noninteractive apt-get purge -y cloudflare-warp >/dev/null 2>&1; then
                        rm -f /etc/apt/sources.list.d/cloudflare-client.list
                        rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
                        crontab -l 2>/dev/null | grep -v "warp-svc" | crontab -
                        hash -r 
                        echo -e "${GREEN}✅ WARP полностью удален из системы.${NC}"
                    else
                        echo -e "${RED}❌ Ошибка! APT заблокирован.${NC}"
                    fi
                fi
                read -p "Нажмите Enter..." ;;
            [Xx]) return ;;
        esac
    done
}
run_warp_menu