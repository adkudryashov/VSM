#!/bin/bash
source /usr/local/bin/_config_and_utils.sh

# ----------------------------------------------------------------------
# НАСТРОЙКИ СЕРВЕРА И ФУНКЦИИ ПРОВЕРКИ
# ----------------------------------------------------------------------

# --- ПРОВЕРКИ СТАТУСА ---

function check_ufw_installed {
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}❌ UFW не установлен. Установите UFW (sudo apt install ufw) для управления PING.${NC}"
        return 1
    fi
    return 0
}

function get_bbr_status {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "active"
    else
        echo "inactive"
    fi
}

function get_ping_status {
    local RULES_FILE="/etc/ufw/before.rules"
    if grep -q "^[[:space:]]*[^#]*ufw-before-input -p icmp --icmp-type echo-request -j DROP" "$RULES_FILE" 2>/dev/null; then
        echo "disabled"
    else
        echo "enabled"
    fi
}

function get_ufw_status {
    if sudo ufw status | grep -q "Status: active"; then echo "active"; else echo "inactive"; fi
}

function get_timezone_status {
    timedatectl | grep "Time zone" | awk '{print $3}'
}

# ----------------------------------------------------------------------
# НОВЫЕ ПУНКТЫ (UFW И TIMEZONE)
# ----------------------------------------------------------------------

# Включение фаервола со страховкой доступа.
#
# Раньше пункт «Включить» делал голый `ufw --force enable`. В Ubuntu
# DEFAULT_INPUT_POLICY="DROP", поэтому на сервере, где правил ещё нет,
# включение немедленно обрывало SSH — пункт меню отрезал администратора от
# машины, с которой он это меню и запустил, без единого предупреждения.
#
# Порт SSH берём из живого конфига sshd, а не хардкодом 22: у кого он перенесён,
# хардкод не спас бы. Порты стека добавляем, если стек установлен, — иначе
# включение фаервола роняет прокси и панель.
function ufw_enable_safely {
    local ports="" p
    # Источники ОБЪЕДИНЯЕМ, а не берём первый непустой. Лишний разрешённый
    # порт безвреден, отсутствующий стоит доступа к серверу.
    #
    # $SSH_CONNECTION — самый достоверный: это порт, через который админ
    # прямо сейчас сидит. Его не хватало, и вот почему это важно: на
    # Ubuntu 22.10+ ssh активируется сокетом, порт задаётся ListenStream в
    # дроп-ине ssh.socket.d, а sshd -T в этом случае печатает 22 — то есть
    # НЕ тот порт, на котором вы работаете. Дальше ufw --force enable при
    # политике DROP отрезает доступ, и чинить приходится через консоль
    # хостера. На стенде это не воспроизводится только потому, что порт там
    # стандартный.
    #
    # ss показывает фактических слушателей sshd — закрывает случай, когда
    # портов несколько.
    ports="$(awk '{print $4}' <<<"${SSH_CONNECTION:-}" 2>/dev/null)"
    ports="$ports $(sshd -T 2>/dev/null | awk '/^port /{print $2}')"
    ports="$ports $(grep -rhoP '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null)"
    ports="$ports $(ss -ltnpH 2>/dev/null | grep -i sshd | awk '{print $4}' | sed 's/.*://')"
    ports="$(tr ' ' '\n' <<<"$ports" | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')"
    [ -z "${ports// /}" ] && ports=22

    echo -e "${YELLOW}>>> Разрешаю доступ ДО включения, чтобы не потерять управление:${NC}"
    for p in $ports; do
        echo -e "    SSH        ${CYAN}${p}/tcp${NC}"
        sudo ufw allow "${p}/tcp" >/dev/null 2>&1
    done

    if [ -f /etc/vsm/telemt.conf ]; then
        # Только TELEMT_PORT. PANEL_PORT наружу НЕ открываем: telemt_panel
        # слушает 127.0.0.1, а снаружи её отдаёт nginx на 443 по секретному
        # префиксу. Раньше здесь открывались оба порта, и включение фаервола
        # возвращало наружу правило для 9444 — то самое, которое переезд
        # панели специально снимает. Слушателя там нет, но правило врёт о
        # состоянии системы и выстрелит, если порт кто-нибудь займёт.
        local TELEMT_PORT=""
        TELEMT_PORT=$(grep -m1 -oP '^TELEMT_PORT=\K.*' /etc/vsm/telemt.conf 2>/dev/null | tr -dc '0-9')
        if [ -n "$TELEMT_PORT" ]; then
            echo -e "    стек       ${CYAN}${TELEMT_PORT}/tcp${NC}"
            sudo ufw allow "${TELEMT_PORT}/tcp" >/dev/null 2>&1
        fi
        # Заодно снимаем правило прежней схемы, если оно осталось.
        local OLD_PANEL_PORT
        OLD_PANEL_PORT=$(grep -m1 -oP '^PANEL_PORT=\K.*' /etc/vsm/telemt.conf 2>/dev/null | tr -dc '0-9')
        [ -n "$OLD_PANEL_PORT" ] && sudo ufw delete allow "${OLD_PANEL_PORT}/tcp" >/dev/null 2>&1
    fi

    if [ -d /etc/x-ui ]; then
        echo -e "    панель     ${CYAN}80/tcp, 443/tcp${NC}"
        sudo ufw allow 80/tcp >/dev/null 2>&1
        sudo ufw allow 443/tcp >/dev/null 2>&1
    fi

    echo ""
    sudo ufw --force enable
}

function show_ufw_menu {
    while true; do
        clear
        echo -e "${CYAN}--- 🛡️ УПРАВЛЕНИЕ ФАЙРВОЛОМ (UFW) -----------------------${NC}"
        echo -e "    Статус: [$(if [ "$(get_ufw_status)" == "active" ]; then echo -e "${GREEN}ВКЛЮЧЕН${NC}"; else echo -e "${RED}ВЫКЛЮЧЕН${NC}"; fi)]"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        echo -e "1) 🟢  Включить UFW"
        echo -e "2) 🔴  Выключить UFW"
        echo -e "3) 🔓  Разрешить порт (allow)"
        echo -e "4) 🔒  Запретить порт (deny)"
        echo -e "5) 🗑️   Удалить правило (по номеру)"
        echo -e "6) 📜  Список правил (с номерами)"
        echo -e "7) 🔄  Перезагрузить (reload)"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        read -p "Выбор: " u_choice

        case $u_choice in
            1) ufw_enable_safely ;;
            2) sudo ufw disable ;;
            3|4) 
                [ "$u_choice" == "3" ] && action="allow" || action="deny"
                
                echo -e "${YELLOW}(Введите 0 или просто Enter для отмены)${NC}"
                read -p "Введите порт: " p
                
                # Проверка на отмену
                if [[ -z "$p" || "$p" == "0" ]]; then
                    echo -e "${BLUE}Действие отменено.${NC}"
                    sleep 1
                    continue
                fi

                echo -e "Выберите протокол для порта $p:"
                echo -e "1) TCP\n2) UDP\n3) Оба (и TCP и UDP)\n0) Отмена"
                read -p "Выбор [1-3, 0]: " proto_choice
                
                case $proto_choice in
                    1) res=$(sudo ufw $action "$p/tcp") ;;
                    2) res=$(sudo ufw $action "$p/udp") ;;
                    3) res=$(sudo ufw $action "$p") ;;
                    *) echo -e "${BLUE}Действие отменено.${NC}"; sleep 1; continue ;;
                esac
                
                echo -e "${YELLOW}Результат:${NC} $res"
                read -p "Нажмите Enter для продолжения..." ;;
            
            5) 
                echo -e "${GREEN}Текущие пронумерованные правила:${NC}"
                sudo ufw status numbered
                echo -e "${YELLOW}(Введите 0 или просто Enter для отмены)${NC}"
                read -p "Введите НОМЕР правила для удаления: " n
                
                if [[ -z "$n" || "$n" == "0" ]]; then
                    echo -e "${BLUE}Удаление отменено.${NC}"
                    sleep 1
                    continue
                fi
                
                # Подтверждение удаления
                read -p "Вы уверены, что хотите удалить правило #$n? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    res=$(sudo ufw --force delete "$n")
                    echo -e "${YELLOW}Результат:${NC} $res"
                else
                    echo -e "${BLUE}Удаление отменено.${NC}"
                fi
                read -p "Нажмите Enter..." ;;
                
            6) 
                echo -e "${GREEN}Текущие правила UFW:${NC}"
                sudo ufw status numbered
                read -p "Нажмите Enter..." ;;
                
            7) 
                sudo ufw reload
                read -p "Нажмите Enter..." ;;
                
            [Xx]) return ;;
        esac
    done
}

function set_timezone_menu {
    while true; do
        clear
        echo -e "${CYAN}--- 🕒 НАСТРОЙКА ЧАСОВОГО ПОЯСА -------------------------${NC}"
        echo -e "    Текущий пояс: ${GREEN}$(get_timezone_status)${NC}"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        echo -e "1) 🏰  Калининград (MSK-1)   5) 🏔️  Екатеринбург (MSK+2)"
        echo -e "2) 🏛️   Москва (MSK)          6) 🌲 Новосибирск (MSK+4)"
        echo -e "3) 🚀  Самара (MSK+1)        7) ⚓ Владивосток (MSK+7)"
        echo -e "4) 🌍  UTC                   8) ❄️  Магадан (MSK+8)"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        read -p "Выбор [1-8, X]: " t_choice
        case $t_choice in
            1) sudo timedatectl set-timezone Europe/Kaliningrad ;;
            2) sudo timedatectl set-timezone Europe/Moscow ;;
            3) sudo timedatectl set-timezone Europe/Samara ;;
            4) sudo timedatectl set-timezone UTC ;;
            5) sudo timedatectl set-timezone Asia/Yekaterinburg ;;
            6) sudo timedatectl set-timezone Asia/Novosibirsk ;;
            7) sudo timedatectl set-timezone Asia/Vladivostok ;;
            8) sudo timedatectl set-timezone Asia/Magadan ;;
            [Xx]) return ;;
        esac
        echo -e "${GREEN}✅ Готово.${NC}" ; sleep 1
    done
}

# ----------------------------------------------------------------------
# BBR: УПРАВЛЕНИЕ ОПТИМИЗАЦИЕЙ СЕТИ (Оригинал)
# ----------------------------------------------------------------------

function enable_bbr {
    local SYSCTL_CONF="/etc/sysctl.conf"
    if [ "$(get_bbr_status)" == "active" ]; then
        echo -e "${YELLOW}BBR уже активен. Действие отменено.${NC}"
        return
    fi
    echo -e "${CYAN}>>> Активация BBR...${NC}"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
    echo "net.core.default_qdisc=fq" | sudo tee -a "$SYSCTL_CONF" > /dev/null
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a "$SYSCTL_CONF" > /dev/null
    sudo sysctl -p > /dev/null
    if [ "$(get_bbr_status)" == "active" ]; then echo -e "${GREEN}✅ BBR успешно активирован.${NC}"; fi
}

function disable_bbr {
    local SYSCTL_CONF="/etc/sysctl.conf"
    if [ "$(get_bbr_status)" == "inactive" ]; then
        echo -e "${YELLOW}BBR уже не используется. Действие отменено.${NC}"
        return
    fi
    echo -e "${CYAN}>>> Отключение BBR (возврат к Cubic)...${NC}"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
    echo "net.core.default_qdisc=fq_codel" | sudo tee -a "$SYSCTL_CONF" > /dev/null
    echo "net.ipv4.tcp_congestion_control=cubic" | sudo tee -a "$SYSCTL_CONF" > /dev/null
    sudo sysctl -p > /dev/null
    if [ "$(get_bbr_status)" == "inactive" ]; then echo -e "${GREEN}✅ BBR успешно отключен.${NC}"; fi
}

function show_bbr_menu {
    while true; do
        clear
        STATUS=$(get_bbr_status)
        echo -e "${CYAN}--- 📈 УПРАВЛЕНИЕ ОПТИМИЗАЦИЕЙ BBR -----------------------${NC}"
        echo -e "    Текущий статус: [$(if [ "$STATUS" == "active" ]; then echo -e "${GREEN}АКТИВЕН${NC}"; else echo -e "${RED}ОТКЛЮЧЕН${NC}"; fi)]"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        echo -e "${GREEN}1) 🟢  Активировать BBR${NC}"
        echo -e "${RED}2) 🔴  Деактивировать BBR (возврат к Cubic)${NC}"
        echo -e "${YELLOW}3) ℹ️   Показать текущий алгоритм (sysctl)${NC}"
        echo -e "${RED}X) 🔙  Назад"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        read -p "Ваш выбор [1-3, X]: " choice
        case $choice in
            1) enable_bbr ;;
            2) disable_bbr ;;
            3) sysctl net.ipv4.tcp_congestion_control ;;
            [Xx]) return ;;
        esac
        read -p "Нажмите Enter для продолжения..."
    done
}

# ----------------------------------------------------------------------
# PING: УПРАВЛЕНИЕ ЗАПРЕТОМ PING (Оригинал)
# ----------------------------------------------------------------------

function manage_ping_logic {
    local RULES_FILE="/etc/ufw/before.rules"
    local ACTION=$1  # "disable" или "enable"

    if [ "$ACTION" == "disable" ]; then
        # 1. Массовая замена ACCEPT на DROP (и в INPUT, и в FORWARD)
        sudo sed -i '/ufw-before-input -p icmp --icmp-type .* -j ACCEPT/s/ACCEPT/DROP/' "$RULES_FILE"
        sudo sed -i '/ufw-before-forward -p icmp --icmp-type .* -j ACCEPT/s/ACCEPT/DROP/' "$RULES_FILE"
        
        # 2. Добавляем source-quench ТОЛЬКО в блок INPUT (после echo-request)
        if ! grep -q "source-quench -j DROP" "$RULES_FILE"; then
            sudo sed -i '/ufw-before-input -p icmp --icmp-type echo-request -j DROP/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$RULES_FILE"
        fi
        echo -e "${GREEN}✅ Пинг запрещен. (Блок FORWARD только переведен в DROP)${NC}"
    else
        # 1. Массовая замена DROP на ACCEPT обратно
        sudo sed -i '/ufw-before-input -p icmp --icmp-type .* -j DROP/s/DROP/ACCEPT/' "$RULES_FILE"
        sudo sed -i '/ufw-before-forward -p icmp --icmp-type .* -j DROP/s/DROP/ACCEPT/' "$RULES_FILE"
        
        # 2. Удаляем source-quench (он был только в INPUT)
        sudo sed -i '/source-quench -j ACCEPT/d' "$RULES_FILE"
        echo -e "${GREEN}✅ Пинг разрешен.${NC}"
    fi
    sudo ufw reload > /dev/null
}

function show_ping_menu {
    check_ufw_installed || return
    PING_STATUS=$(get_ping_status)

    echo -e "\n${CYAN}>>> УПРАВЛЕНИЕ ПИНГОМ (ICMP)${NC}"
    if [ "$PING_STATUS" == "enabled" ]; then
        echo -e "Текущий статус: ${GREEN}РАЗРЕШЕН${NC}"
        read -p "Желаете ЗАПРЕТИТЬ пинг? [y/N]: " act
        [[ "$act" =~ ^[Yy]$ ]] && manage_ping_logic "disable"
    else
        echo -e "Текущий статус: ${RED}ЗАПРЕЩЕН${NC}"
        read -p "Желаете РАЗРЕШИТЬ пинг? [y/N]: " act
        [[ "$act" =~ ^[Yy]$ ]] && manage_ping_logic "enable"
    fi
    sleep 2
}
# ----------------------------------------------------------------------
# SSL: УПРАВЛЕНИЕ СЕРТИФИКАТАМИ
# ----------------------------------------------------------------------

# Глобальная переменная директории для сертификатов
SSL_SAVE_DIR="/root/cert"

# Возврат служб, остановленных ради certbot --standalone.
#
# Вынесено в функцию и идемпотентно, потому что вызывается из двух мест: штатно
# после certbot и из trap по сигналу. Прежде восстановление было только в
# штатном пути, а trap не стоял нигде — Ctrl+C во время выпуска (certbot умеет
# висеть на проверке DNS, и соблазн прервать максимальный) или обрыв SSH
# оставляли nginx выключенным. Следом systemd уносил telemt по
# Requires=nginx.service, и прокси лежал молча: на экране ничего, служба
# enabled, после ребута всё поднимется — то есть причину потом не найти.
function restore_stopped_services {
    [ -n "$STOPPED_SERVICES" ] || return 0
    echo -e "\n${CYAN}Возвращаю остановленные службы:${STOPPED_SERVICES}${NC}"
    for svc in $STOPPED_SERVICES; do
        sudo systemctl start "$svc" 2>/dev/null
    done
    # telemt держится за nginx и мог уйти следом — поднимаем, если он
    # установлен и не поднялся сам.
    if [ -f /etc/telemt/telemt.toml ] && ! systemctl is-active --quiet telemt; then
        sudo systemctl start telemt 2>/dev/null
    fi
    for svc in $STOPPED_SERVICES; do
        systemctl is-active --quiet "$svc" && \
            echo -e "${GREEN}    $svc работает${NC}" || \
            echo -e "${RED}    $svc НЕ поднялся — проверьте journalctl -u $svc${NC}"
    done
    if [ -f /etc/telemt/telemt.toml ]; then
        systemctl is-active --quiet telemt && \
            echo -e "${GREEN}    telemt работает${NC}" || \
            echo -e "${RED}    telemt НЕ поднялся — проверьте journalctl -u telemt${NC}"
    fi
    STOPPED_SERVICES=""
}

function manage_ssl_menu {
    # Проверяем и ставим certbot, если его нет
    if ! ensure_packages certbot; then
        read -p "Нажмите Enter для возврата..."
        return
    fi

    # Создаем папку, если ее нет
    mkdir -p "$SSL_SAVE_DIR"

    while true; do
        clear
        echo -e "${CYAN}--- 🔐 УПРАВЛЕНИЕ СЕРТИФИКАТАМИ (SSL/ACME) ----------------${NC}"
        echo -e "    Папка сохранения: ${GREEN}$SSL_SAVE_DIR${NC}"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        echo -e "1) ➕  Получить сертификат (Один домен или Multi-domain SAN)"
        echo -e "2) 📋  Список сохраненных сертификатов"
        echo -e "3) ❌  Отозвать и удалить сертификат"
        echo -e "4) ⚙️   Изменить папку по умолчанию"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}----------------------------------------------------------${NC}"
        read -p "Выбор: " ssl_choice

        case $ssl_choice in
            1)
                read -p "Сколько доменов включить в сертификат? (по умолчанию 1): " d_count
                [[ ! "$d_count" =~ ^[0-9]+$ ]] && d_count=1
                
                DOMAINS_ARGS=""
                FIRST_DOMAIN=""
                for (( i=1; i<=d_count; i++ )); do
                    read -p "Введите домен #$i (например, example.com): " dom
                    if [ -n "$dom" ]; then
                        DOMAINS_ARGS="$DOMAINS_ARGS -d $dom"
                        [ -z "$FIRST_DOMAIN" ] && FIRST_DOMAIN="$dom"
                    fi
                done
                
                if [ -z "$FIRST_DOMAIN" ]; then
                    echo -e "${RED}Домены не введены. Отмена.${NC}"; sleep 1; continue
                fi

                # Весь ввод собираем ДО того, как что-то останавливать. Раньше
                # вопрос про email задавался уже при выключенном nginx: пока
                # человек искал почту или отходил от терминала, панель и прокси
                # лежали. Окно простоя не должно зависеть от скорости чтения.
                echo -e "${YELLOW}Email нужен Let's Encrypt только для уведомлений об истечении сертификата.${NC}"
                IFS= read -r -p "Введите email (или нажмите Enter, чтобы выпустить без почты): " acme_email

                if [ -z "$acme_email" ]; then
                    EMAIL_ARG="--register-unsafely-without-email"
                else
                    EMAIL_ARG="-m $acme_email"
                fi

                # Автоматически освобождаем 80 порт перед запросом.
                #
                # Запоминаем, что именно остановили: раньше службы глушились и
                # не запускались НИКОГДА — ни на успехе, ни на ошибке. Пункт
                # печатал «Сертификаты успешно выпущены», а сервер в этот
                # момент уже лежал: nginx выключен, панель недоступна, а следом
                # systemd уносил и telemt — у него Requires=nginx.service.
                STOPPED_SERVICES=""
                if ss -tlpn | grep -q ":80 "; then
                    echo -e "${YELLOW}Порт 80 занят! Временно останавливаем службы (nginx/apache)...${NC}"
                    for svc in nginx apache2; do
                        systemctl is-active --quiet "$svc" 2>/dev/null || continue
                        sudo systemctl stop "$svc" 2>/dev/null && \
                            STOPPED_SERVICES="$STOPPED_SERVICES $svc"
                    done
                fi

                # Ловушка ставится сразу после остановки и снимается сразу
                # после возврата: между этими точками прерывание или обрыв
                # связи не должны оставить сервер без nginx и telemt.
                trap 'restore_stopped_services; trap - INT TERM HUP; echo -e "\n${RED}Прервано пользователем.${NC}"; return 130' INT TERM HUP

                echo -e "${CYAN}Запрашиваем сертификат...${NC}"
                # Запрашиваем через standalone сервер
                sudo certbot certonly --standalone $DOMAINS_ARGS --non-interactive --agree-tos $EMAIL_ARG
                CERT_RC=$?

                # Возвращаем всё, что останавливали, ДО разбора результата и
                # независимо от исхода: неудачный выпуск — не повод оставить
                # сервер лежать.
                restore_stopped_services
                trap - INT TERM HUP

                if [ "$CERT_RC" -eq 0 ]; then
                    # Копируем ключи в пользовательскую папку
                    mkdir -p "$SSL_SAVE_DIR/$FIRST_DOMAIN"
                    cp /etc/letsencrypt/live/$FIRST_DOMAIN/fullchain.pem "$SSL_SAVE_DIR/$FIRST_DOMAIN/fullchain.pem"
                    cp /etc/letsencrypt/live/$FIRST_DOMAIN/privkey.pem "$SSL_SAVE_DIR/$FIRST_DOMAIN/privkey.pem"
                    
                    echo -e "\n${GREEN}✅ Сертификаты успешно выпущены и скопированы!${NC}"
                    echo -e "${YELLOW}Путь к Fullchain (Сертификат): ${NC}$SSL_SAVE_DIR/$FIRST_DOMAIN/fullchain.pem"
                    echo -e "${YELLOW}Путь к Privkey (Ключ):       ${NC}$SSL_SAVE_DIR/$FIRST_DOMAIN/privkey.pem"
                else
                    echo -e "\n${RED}❌ Ошибка при выпуске сертификата.${NC}"
                    echo -e "Убедитесь, что IP домена настроен правильно, а порты 80 и 443 открыты в UFW."
                fi
                read -p "Нажмите Enter..." ;;
            
            2)
                echo -e "${GREEN}Сертификаты в базе системы (Certbot):${NC}"
                sudo certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry Date' || echo "Нет активных."
                
                echo -e "\n${GREEN}Сертификаты в вашей папке ($SSL_SAVE_DIR):${NC}"
                ls -lh "$SSL_SAVE_DIR" 2>/dev/null || echo "Папка пуста."
                read -p "Нажмите Enter..." ;;

            3)
                echo -e "${GREEN}Доступные сертификаты для удаления:${NC}"
                sudo certbot certificates 2>/dev/null | grep "Certificate Name:"
                
                echo -e "${YELLOW}(Введите 0 или просто Enter для отмены)${NC}"
                read -p "Введите имя сертификата (Certificate Name) для отзыва: " del_dom
                
                if [[ -z "$del_dom" || "$del_dom" == "0" ]]; then
                    echo -e "${BLUE}Удаление отменено.${NC}"; sleep 1; continue
                fi
                
                # Отзываем и удаляем
                sudo certbot revoke --cert-name "$del_dom" --delete-after-revoke --reason unspecified
                rm -rf "$SSL_SAVE_DIR/$del_dom"
                
                echo -e "${GREEN}✅ Сертификат $del_dom отозван и удален со всех папок.${NC}"
                read -p "Нажмите Enter..." ;;

            4)
                read -p "Введите новый путь [текущий: $SSL_SAVE_DIR]: " new_dir
                if [ -n "$new_dir" ]; then
                    SSL_SAVE_DIR="$new_dir"
                    mkdir -p "$SSL_SAVE_DIR"
                    echo -e "${GREEN}✅ Путь успешно изменен.${NC}"
                fi
                ;;
            [Xx]) return ;;
        esac
    done
}
# ----------------------------------------------------------------------
# ГЛАВНЫЙ ЦИКЛ МЕНЮ УСТАНОВКИ (Оригинал + 2 пункта)
# ----------------------------------------------------------------------

function run_setup_menu {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}                    ${GREEN}⚙️   НАСТРОЙКА И ОПТИМИЗАЦИЯ${NC}                           ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
        
        BBR_STATUS=$(get_bbr_status)
        PING_STATUS=$(get_ping_status)
        
        # IPv6 читаем тем же способом, что и ipv6-menu: отключение делается
        # через sysctl disable_ipv6, поэтому смотрим именно на него.
        if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "1" ]; then
            IPV6_LINE="${RED}ОТКЛЮЧЁН${NC}"
        else
            IPV6_LINE="${GREEN}ВКЛЮЧЁН${NC}"
        fi
        echo ""
        echo -e "${BLUE}  ── СТАТУС ─────────────────────────────────────────────────────────────────${NC}"
        echo -e "   📈  BBR   [$(if [ "$BBR_STATUS" == "active" ]; then echo -e "${GREEN}АКТИВЕН${NC}"; else echo -e "${RED}ОТКЛЮЧЕН${NC}"; fi)]      🏓  ICMP  [$(if [ "$PING_STATUS" == "enabled" ]; then echo -e "${GREEN}РАЗРЕШЁН${NC}"; else echo -e "${RED}ЗАПРЕЩЁН${NC}"; fi)]"
        echo -e "   🛡️   UFW   [$(if [ "$(get_ufw_status)" == "active" ]; then echo -e "${GREEN}АКТИВЕН${NC}"; else echo -e "${RED}ОТКЛЮЧЕН${NC}"; fi)]      🌐  IPv6  [${IPV6_LINE}]"
        echo -e "   🕒  Часовой пояс   ${YELLOW}$(get_timezone_status)${NC}"

        echo ""
        echo -e "${BLUE}  ── СЕТЬ ─────────────────────────────────────────────────────────────────${NC}"
        echo -e "   ${YELLOW}1${NC}  📈  BBR                  ${BLUE}Алгоритм управления перегрузкой TCP${NC}"
        echo -e "   ${YELLOW}2${NC}  🏓  ICMP                 ${BLUE}Ответы на ping: разрешить или запретить${NC}"
        echo -e "   ${YELLOW}3${NC}  🛡️   Фаервол UFW          ${BLUE}Порты, правила, включение с защитой SSH${NC}"
        echo -e "   ${YELLOW}4${NC}  🌐  IPv6                 ${BLUE}Включение и отключение на уровне ядра${NC}"
        echo ""
        echo -e "${BLUE}  ── СЕРТИФИКАТЫ И ПРОЧЕЕ ─────────────────────────────────────────────────${NC}"
        echo -e "   ${YELLOW}5${NC}  🔐  SSL-сертификаты      ${BLUE}Выпуск, продление, удаление Let's Encrypt${NC}"
        echo -e "   ${YELLOW}6${NC}  🕒  Часовой пояс         ${BLUE}Смена часового пояса сервера${NC}"
        echo -e "   ${YELLOW}7${NC}  ☁️   Cloudflare WARP      ${BLUE}Исходящий трафик через WARP${NC}"
        echo ""
        echo -e "   ${RED}X${NC}  🔙  Назад"
        echo ""

        read -p "Ваш выбор [1-7, X]: " choice
        case $choice in
            1) show_bbr_menu ;;
            2) show_ping_menu ;;
            3) show_ufw_menu ;;
            4) bash /usr/local/bin/ipv6-menu ;;
            5) manage_ssl_menu ;;
            6) set_timezone_menu ;;
            7)
            bash /usr/local/bin/menu_warp.sh
            ;;
            [Xx]) return ;;
        esac
    done
}
run_setup_menu
