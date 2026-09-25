#!/bin/bash
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh" || {
    echo "Не найдена lib/common.sh — переустановите VSM: bash install.sh"; exit 1; }

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

# shellcheck disable=SC1091
source "$VSM_LIB/beszel_agent.sh"
# shellcheck disable=SC1091
source "$VSM_LIB/beszel_hub.sh"

# ----------------------------------------------------------------------
# Хаб beszel на этом сервере. Подробности — в шапке lib/beszel_hub.sh.
# ----------------------------------------------------------------------
function install_beszel_hub {
    local domain port email p2 def_domain def_port need_account=1
    def_domain="$(grep -m1 '^DOMAIN_PANEL=' /etc/vsm/telemt.conf 2>/dev/null | cut -d= -f2- | tr -d '"')"
    def_port="$(_bh_nginx_port)"; def_port="${def_port:-8445}"
    echo ""
    _bh_say "Хаб встанет на петлю, наружу его отдаст nginx по TLS на домене с"
    _bh_say "сертификатом этого сервера. Учётную запись VSM заведёт сам ДО того,"
    _bh_say "как хаб станет виден снаружи: у свежего хаба администратором"
    _bh_say "становится первый, кто открыл страницу."
    echo ""
    read -r -p "Домен хаба${def_domain:+ [$def_domain]}: " domain || return
    domain="${domain:-$def_domain}"
    read -r -p "Порт снаружи [$def_port]: " port || return
    port="${port:-$def_port}"
    if beszel_hub_installed && _bh_health && ! beszel_hub_first_run; then
        need_account=0
    fi
    if [ "$need_account" = 1 ]; then
        read -r -p "Email для входа в хаб: " email || return
        # Пароль не печатается и не попадает в аргументы процессов.
        IFS= read -rs -p "Пароль (от 8 символов): " BH_PASSWORD || return; echo ""
        IFS= read -rs -p "Пароль ещё раз: " p2 || return; echo ""
        if [ "$BH_PASSWORD" != "$p2" ]; then
            unset BH_PASSWORD p2; echo -e "${RED}❌ Пароли не совпали.${NC}"; return
        fi
        if [ "${#BH_PASSWORD}" -lt 8 ]; then
            unset BH_PASSWORD p2; echo -e "${RED}❌ Пароль короче 8 символов — хаб его не примет.${NC}"; return
        fi
        export BH_PASSWORD
    fi
    beszel_hub_install "$domain" "$port" "$email" || true
    unset BH_PASSWORD p2
    if [ -n "$(beszel_hub_url)" ]; then
        echo ""
        _bh_say "Дальше: войдите в хаб, «Настройки → Токены и отпечатки» — включите"
        _bh_say "общий токен и сделайте его постоянным. Там же ключ хаба. С ними"
        _bh_say "агенты подключаются пунктом 1 — здесь и на других серверах."
    fi
}

# ----------------------------------------------------------------------
# АГЕНТ И ХАБ BESZEL. Подробности — в шапках lib/beszel_agent.sh и
# lib/beszel_hub.sh.
# ----------------------------------------------------------------------
function manage_beszel_agent {
    local ch hub key token def yn hub_url
    while true; do
        clear 2>/dev/null
        ui_title "🖥  BESZEL: АГЕНТ И ХАБ"
        ui_section "СОСТОЯНИЕ"
        echo -e "   Агент: $(beszel_agent_state)"
        if beszel_agent_installed; then
            echo -e "   ${C_DESC}версия $(beszel_agent_version), хаб $(beszel_agent_hub_url)${NC}"
        fi
        hub_url=""
        if beszel_hub_installed; then
            hub_url="$(beszel_hub_url)"
            echo -e "   Хаб здесь: ${hub_url:-стоит, наружу не выпущен ($(beszel_hub_listen))}"
        fi
        echo ""
        echo -e "   ${C_DESC}Агент сам ходит к хабу по WebSocket — порт на этом сервере${NC}"
        echo -e "   ${C_DESC}открывать не нужно. Ключ и токен показывает хаб: «Добавить${NC}"
        echo -e "   ${C_DESC}систему». Для новых серверов удобнее общий токен: «Настройки →${NC}"
        echo -e "   ${C_DESC}Токены и отпечатки» — один на все, сервер появится в хабе сам.${NC}"
        echo ""
        ui_section "ДЕЙСТВИЯ"
        ui_item "1" "📥" "Поставить агент"  "Или переподключить к другому хабу"
        ui_danger_item "2" "Удалить агент"  "Служба, бинарь, таймер обновления"
        ui_item "3" "📊" "Хаб на этом сервере"  "Поставить или сменить адрес"
        ui_item "X" "🔙" "Назад"
        echo ""
        read -p "Ваш выбор [1-3, X]: " ch || break
        case "$ch" in
            1)
                def="$(beszel_agent_hub_url 2>/dev/null)"
                # Хаб на этой же машине — агенту ближе всего петля: так он
                # не зависит ни от nginx, ни от сертификата. Проверено на 179.
                if [ -z "$def" ] && beszel_hub_installed; then
                    def="http://$(beszel_hub_listen)"
                fi
                read -r -p "Адрес хаба${def:+ [$def]}: " hub || break
                hub="${hub:-$def}"
                read -r -p "Ключ хаба (ssh-ed25519 …): " key || break
                # Токен не печатается: он даёт право зарегистрировать сервер в хабе.
                IFS= read -rs -p "Токен: " token || break
                echo ""
                beszel_agent_install "$hub" "$key" "$token" || true
                unset token
                read -p "Нажмите Enter..."
                ;;
            2)
                read -r -p "$(echo -e "${RED}Удалить агент? Сервер пропадёт из хаба. [y/N]: ${NC}")" yn || break
                [[ "$yn" =~ ^[YyДд]$ ]] && { beszel_agent_remove || true; }
                read -p "Нажмите Enter..."
                ;;
            3)
                install_beszel_hub
                read -p "Нажмите Enter..."
                ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
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
        ui_item "9" "🖥" "beszel"         "Агент: $(beszel_agent_state)"
        echo ""
        # Завершение процесса уехало с 9 на 10 из-за агента beszel — в эту
        # сторону сдвиг безопасен: по старой привычке попадёшь на безобидный
        # экран агента, а не на kill.
        ui_danger_item "10" "Завершить процесс" "kill: снимает выбранный процесс"
        ui_item "X" "🔙" "Назад"
        echo ""
        
        read -p "Ваш выбор: " choice || break
        case $choice in
            1)
                htop
                ;;
            2)
                echo -e "\n${CYAN}--- Параметры сканирования (ncdu) ---${NC}"
                ui_item "1" "💽" "Весь диск"      "/ — целиком, дольше всего"
                ui_item "2" "📜" "Системные логи" "/var/log"
                ui_item "3" "📂" "Текущая папка"  "$(pwd)"
                ui_item "4" "✏" "Свой путь"      "Ввести вручную"
                read -p "Выбор: " ncdu_opt || break
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
                read -p "Выберите интерфейс: " net_opt || break
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
                read -p "Введите IP или домен (например, 8.8.8.8 или google.com): " target || break
                if [ -z "$target" ]; then continue; fi
                ui_item "1" "🏓" "Обычный ping"    "4 пакета и остановка"
                ui_item "2" "♾" "Непрерывный ping" "До Ctrl+C"
                ui_item "3" "🧭" "Трассировка MTR" "Путь до узла в реальном времени"
                read -p "Выбор: " ping_opt || break
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
                ui_item "1" "🔗" "Только TCP"  "Слушающие сокеты TCP"
                ui_item "2" "📡" "Только UDP"  "Слушающие сокеты UDP"
                ui_item "3" "🔀" "Все порты"   "TCP и UDP вместе"
                read -p "Выбор: " port_opt || break
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
            9) manage_beszel_agent ;;
            10)
                echo -e "\n${CYAN}--- Завершение процессов ---${NC}"
                ui_item        "1" "🔍" "Найти по имени"  "Показать PID, ничего не трогая"
                ui_danger_item "2" "Убить по PID"   "kill -9, без вопросов"
                ui_danger_item "3" "Убить по имени" "killall -9 — разом все совпавшие"
                read -p "Выбор: " kill_opt || break
                case $kill_opt in
                    1)
                        read -p "Введите часть имени: " s_name || break
                        echo -e "${YELLOW}Найденные процессы:${NC}"
                        ps aux | grep -i "$s_name" | grep -v "grep" | awk '{print "PID: " $2 " | Владелец: " $1 " | Команда: " $11}'
                        ;;
                    2)
                        read -p "Введите PID: " k_pid || break
                        if kill -9 "$k_pid" 2>/dev/null; then echo -e "${GREEN}Процесс $k_pid жестоко убит.${NC}"; else echo -e "${RED}Ошибка: Процесс не найден или нет прав.${NC}"; fi
                        ;;
                    3)
                        read -p "Введите точное имя (например, nginx): " k_name || break
                        if killall -9 "$k_name" 2>/dev/null; then echo -e "${GREEN}Процессы $k_name убиты.${NC}"; else echo -e "${RED}Процесс не найден.${NC}"; fi
                        ;;
                    *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
                esac
                read -p "Нажмите Enter..."
                ;;
            8)
                # Отчёт печатается СРАЗУ, до всякого выбора.
                #
                # Прежде пункты удаляли молча: человек нажимал «выполнить всё
                # сразу» и не знал ни что уйдёт, ни сколько освободится, ни
                # почему место кончилось. А кончалось оно не от кэша apt: на
                # замере 2 ГБ занимали распакованные исходники сборки, которых
                # не касался ни один из прежних пунктов.
                bash "$VSM_ROOT/tools/disk-cleanup.sh" --report
                ui_item "1" "🧹" "Убрать мусор"        "Исходники сборки, кэш пакетов, старые ядра, журнал сверх потолка"
                ui_item "2" "🔧" "Устранить причину"   "Потолок журналу и отмена дублирования в syslog — меняет настройку системы"
                ui_item "3" "🔄" "Вернуть как было"    "Откат настройки журналирования"
                ui_item "X" "🔙" "Назад"
                read -p "Выбор: " clean_opt || break
                case $clean_opt in
                    1) bash "$VSM_ROOT/tools/disk-cleanup.sh" --clean ;;
                    2)
                        # Отдельное подтверждение: это не уборка, а изменение
                        # поведения системы, и в «выполнить всё сразу» такому
                        # не место.
                        echo -e "\n${YELLOW}Будет изменено системное журналирование:${NC}"
                        echo -e "  • журналу задаётся потолок вместо умолчания «10% диска»"
                        echo -e "  • отменяется дублирование записей в /var/log/syslog"
                        echo -e "${C_DESC}  Логи не теряются: всё читается через journalctl.${NC}"
                        read -p "Продолжить? [y/N]: " ans || break
                        [[ "$ans" =~ ^[YyДд]$ ]] \
                            && bash "$VSM_ROOT/tools/disk-cleanup.sh" --logging-tune \
                            || echo -e "${BLUE}Отменено.${NC}"
                        ;;
                    3) bash "$VSM_ROOT/tools/disk-cleanup.sh" --logging-reset ;;
                    [Xx]) ;;
                    *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
                esac
                read -p "Нажмите Enter..."
                ;;
            7)
                echo -e "\n${CYAN}--- Проверка привязки домена ---${NC}"
                read -p "Введите домен (например, sub.domain.com): " check_domain || break
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
