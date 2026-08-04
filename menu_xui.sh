#!/bin/bash
source /usr/local/bin/_config_and_utils.sh

# ----------------------------------------------------------------------
# X-UI PRO (3x-ui-pro): УПРАВЛЕНИЕ (Вынесенный блок)
# https://github.com/mozaroc/3x-ui-pro
# ----------------------------------------------------------------------

XUI_PRO_REPO="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main"

# Установщик и патч 3x-ui-pro очищают /etc/nginx/sites-enabled целиком.
# Если на сервере поднят стек telemt, его self-SNI vhost живёт в conf.d и
# это переживает — но vhost ссылается на пути из конфига панели, которые
# патч мог перегенерировать. Поэтому после обеих операций напоминаем
# прогнать диагностику.
function warn_telemt_after_panel_change {
    if [ -f /etc/telemt/telemt.toml ]; then
        echo -e "\n${YELLOW}⚠️  На сервере установлен стек telemt.${NC}"
        echo -e "${YELLOW}    Панель могла перегенерировать свои nginx-конфиги."
        echo -e "    Проверь маскировку: главное меню -> 'Стек telemt / MTProto'"
        echo -e "    -> 'Статус и диагностика'. При сбое — 'Восстановить маскировку'.${NC}"
    fi
}

function install_xui_pro {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}          📥  УСТАНОВКА X-UI PRO (3x-ui-pro) 📥        ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}Устанавливает: 3x-ui, nginx, SSL (Let's Encrypt), Clash-подписку, диагностику сети.${NC}"
    echo -e "${YELLOW}Нужны два домена/поддомена: один для панели, другой для REALITY.${NC}"
    echo ""

    read -p "Автоопределение доменов (без ручного ввода)? [y/N]: " auto_domain
    local xui_args=()

    if [[ "$auto_domain" =~ ^[Yy]$ ]]; then
        xui_args+=(-auto_domain y)
    else
        read -p "Домен панели (например panel.example.com): " subdomain
        read -p "Домен для REALITY (другой домен/поддомен): " reality_domain
        [ -n "$subdomain" ] && xui_args+=(-subdomain "$subdomain")
        [ -n "$reality_domain" ] && xui_args+=(-reality_domain "$reality_domain")
    fi

    read -p "Версия 3x-ui (Enter = последняя): " version
    [ -n "$version" ] && xui_args+=(-version "$version")

    # Установщик 3x-ui-pro содержит check_cpu(): он ищет «QEMU» в
    # /proc/cpuinfo и обрывается с exit 1, если процессор эмулируется. Проверка
    # снимается на лету — вызов check_cpu заменяется на no-op. Сам скрипт у
    # автора не трогаем, патч живёт только в памяти этого запуска.
    #
    # Зачем: у ряда хостеров CPU отдаётся как QEMU Virtual CPU, и панель было
    # не поставить вовсе. Апстрим считает это требованием ради скорости Xray —
    # на эмулированном процессоре он будет медленнее, и это осознанный размен.
    echo -e "${CYAN}>>> Запуск установки 3x-ui-pro...${NC}"

    # Скачиваем во временный файл, а не через `bash <(curl ...)`: при неудачной
    # загрузке подстановка процесса отдаёт пустой ввод, bash выполняет пустой
    # скрипт и выходит с нулём — сбой выглядел бы как успешная установка.
    # Отдельный файл нужен ещё и потому, что здесь применяется правка.
    local installer; installer=$(mktemp /tmp/vsm-xui.XXXXXX.sh)
    if ! curl -fsSL --max-time 60 "$XUI_PRO_REPO/x-ui-latest.sh" -o "$installer" \
       || [ ! -s "$installer" ]; then
        rm -f "$installer"
        echo -e "${RED}❌ Не удалось загрузить установщик 3x-ui-pro.${NC}"
        read -p "Нажмите Enter для продолжения..."
        return
    fi
    if grep -q '^check_cpu$' "$installer"; then
        sed -i 's/^check_cpu$/: # проверка CPU снята VSM/' "$installer"
    fi
    bash "$installer" "${xui_args[@]}"
    rm -f "$installer"
    warn_telemt_after_panel_change
    read -p "Нажмите Enter для продолжения..."
}

function patch_xui_pro {
    echo -e "${CYAN}>>> Применение патча к текущей установке (без изменения БД)...${NC}"
    run_remote_script "$XUI_PRO_REPO/x-ui-patch.sh"
    warn_telemt_after_panel_change
    read -p "Нажмите Enter для продолжения..."
}

function manage_adguard {
    while true; do
        clear
        echo -e "${CYAN}--- 🛡️  ADGUARD HOME (DNS-over-HTTPS + блокировка рекламы) ---${NC}"
        echo -e "${YELLOW}Ставится на домен панели, без отдельного домена и портов (через 443).${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "1) 📥  Установить или обновить AdGuard Home"
        echo -e "2) 🗑️   Удалить AdGuard Home"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        read -p "Выбор: " ag_choice
        case $ag_choice in
            1)
                run_remote_script "$XUI_PRO_REPO/x-ui-adguard.sh"
                read -p "Нажмите Enter для продолжения..."
                ;;
            2)
                # Подтверждение обязательно: AdGuard стоит на домене панели и
                # обслуживает DNS через 443, то есть промах по клавише в этом
                # меню молча уносит рабочий DNS-сервис.
                read -p "$(echo -e "${RED}Удалить AdGuard Home? [y/N]: ${NC}")" ag_confirm
                if [[ "$ag_confirm" =~ ^[Yy]$ ]]; then
                    run_remote_script "$XUI_PRO_REPO/x-ui-adguard.sh" -uninstall y
                else
                    echo -e "${BLUE}Отменено.${NC}"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
        esac
    done
}

function ensure_backup_script {
    if [ ! -x /usr/local/bin/x-ui-backup ]; then
        echo -e "${YELLOW}>>> Загрузка скрипта бэкапа...${NC}"
        sudo wget -qO /usr/local/bin/x-ui-backup "$XUI_PRO_REPO/assets/backup/x-ui-backup.sh"
        sudo chmod +x /usr/local/bin/x-ui-backup
    fi
}

function manage_backup {
    ensure_backup_script
    while true; do
        clear
        echo -e "${CYAN}--- 💾  БЭКАП / ВОССТАНОВЛЕНИЕ X-UI PRO ---------------${NC}"
        echo -e "1) 📦  Создать бэкап"
        echo -e "2) 📋  Список бэкапов"
        echo -e "3) ♻️   Восстановить из бэкапа"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        read -p "Выбор: " b_choice
        case $b_choice in
            1) sudo x-ui-backup backup; read -p "Нажмите Enter для продолжения..." ;;
            2) sudo x-ui-backup list; read -p "Нажмите Enter для продолжения..." ;;
            3)
                sudo x-ui-backup list
                read -p "Введите полный путь к файлу бэкапа: " b_path
                if [ -n "$b_path" ]; then
                    sudo x-ui-backup restore "$b_path"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
        esac
    done
}

# Учётные данные панели 3x-ui.
#
# VSM их не добывает, а запоминает: пароль панели лежит bcrypt-хэшем и не
# читается ничем, а установщик печатает его ровно один раз. Пункт ничего не
# меняет в самой панели — это записная книжка, и текст обязан говорить это
# прямо, иначе его примут за смену пароля.
function manage_xui_credentials {
    while true; do
        clear
        echo -e "${CYAN}--- 🔑  УЧЁТНЫЕ ДАННЫЕ ПАНЕЛИ 3x-ui ------------------${NC}"
        local cur_user cur_pass
        cur_user=$(xui_admin_user); cur_pass=$(xui_admin_pass)
        if [ -n "$cur_user" ] || [ -n "$cur_pass" ]; then
            # printf по той же причине, что и в шапке: значение не должно
            # разбираться на escape-последовательности.
            printf "    Логин:   ${YELLOW}%s${NC}\n" "${cur_user:-—}"
            printf "    Пароль:  ${YELLOW}%s${NC}\n" "${cur_pass:-—}"
            echo -e "    ${BLUE}Файл: $XUI_CONF_FILE (права 600)${NC}"
        else
            echo -e "    ${YELLOW}Не записаны.${NC}"
        fi
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "${YELLOW}Пункт 1 НЕ меняет пароль панели — он запоминает тот,${NC}"
        echo -e "${YELLOW}что уже действует, чтобы не искать его при каждом входе.${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "1) ✏️   Записать или обновить логин и пароль"
        echo -e "2) 🧹  Стереть запись"
        echo -e "X) 🔙  Назад"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        read -p "Выбор: " c_choice
        case $c_choice in
            1)
                local new_user new_pass
                # IFS= read -r, а не голый read: без -r обратный слэш считается
                # экранированием и молча пропадает, без IFS= обрезаются крайние
                # пробелы. Пароль после этого не подошёл бы к панели, а шапка
                # показывала бы его как верный — ровно тот исход, который ниже
                # объявлен худшим. Весь остальной тракт (_secret_clean, printf
                # %q, printf %s) слэш бережёт, и терять его на вводе нельзя.
                #
                # -s у пароля: он и так будет показан в шапке, но печатать его
                # ещё и в момент набора незачем — набор попадает в запись
                # сессии и в скроллбэк там, где его никто не ждёт.
                IFS= read -r -p "Логин панели: " new_user
                IFS= read -rs -p "Пароль панели: " new_pass
                echo
                # Пустой ввод отменяет операцию, а не пишется в файл: пустой
                # пароль в хранилище означал бы, что шапка меню уверенно
                # показывает неверные данные.
                if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
                    echo -e "${BLUE}Пусто — ничего не записано.${NC}"
                elif xui_credentials_save "$new_user" "$new_pass"; then
                    echo -e "${GREEN}✓ Записано в $XUI_CONF_FILE (права 600).${NC}"
                else
                    echo -e "${RED}❌ Не удалось записать (причина выше).${NC}"
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            2)
                rm -f "$XUI_CONF_FILE"
                echo -e "${GREEN}✓ Запись стёрта. Пароль самой панели не тронут.${NC}"
                read -p "Нажмите Enter для продолжения..."
                ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
        esac
    done
}

function uninstall_xui_pro {
    # Ввод слова, а не [y/N]: здесь сносится панель вместе с базой инбаундов и
    # пользователей и вычищается nginx — восстановить это переустановкой
    # нельзя. Остальные удаления такого масштаба в проекте (стек telemt, боты)
    # тоже требуют напечатать УДАЛИТЬ; одиночная клавиша для самой тяжёлой
    # операции была самым слабым подтверждением во всём меню.
    #
    # Список сверен с uninstall_xui() в x-ui-latest.sh автора. Прежний текст
    # обещал снести сертификаты — их установщик не трогает вовсе, и человек
    # шёл выпускать заново то, что и так на месте. Зато он молчал о главном:
    # /etc/nginx удаляется целиком, а вместе с ним и маскировка стека telemt.
    echo -e "${RED}⚠️  Будут удалены:"
    echo -e "      • панель 3x-ui-pro с базой инбаундов и пользователей"
    echo -e "      • nginx целиком: пакет вычищается (purge), каталог /etc/nginx удаляется"
    echo -e "      • /var/www/html, страницы подписок и диагностики${NC}"
    echo -e "${GREEN}    Сертификаты Let's Encrypt в /etc/letsencrypt НЕ удаляются.${NC}"
    if [ -f /etc/telemt/telemt.toml ]; then
        echo -e "\n${RED}⚠️  На сервере установлен стек telemt, и удаление панели его сломает:"
        echo -e "    вместе с /etc/nginx исчезнет conf.d/telemt-mask.conf, вместе с"
        echo -e "    /var/www/html — webroot маскировки, а за остановленным nginx"
        echo -e "    systemd унесёт и telemt (Requires=nginx.service)."
        echo -e "    Панель придётся ставить заново и прогонять «Восстановить маскировку».${NC}"
    fi
    read -p "$(echo -e "${RED}Введите УДАЛИТЬ для подтверждения: ${NC}")" confirm
    if [ "$confirm" == "УДАЛИТЬ" ]; then
        run_remote_script "$XUI_PRO_REPO/x-ui-latest.sh" -uninstall y
    else
        echo -e "${BLUE}Отменено.${NC}"
    fi
    read -p "Нажмите Enter для продолжения..."
}

function manage_xui_service {
    local SERVICE_NAME=$XUI_SERVICE
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}         🎛️  УПРАВЛЕНИЕ X-UI PRO (3x-ui-pro) 🎛️        ${NC}"
        echo -e "${CYAN}======================================================${NC}"

        STATUS_XUI=$(get_service_status $SERVICE_NAME)
        STATUS_DISPLAY=$(if [ "$STATUS_XUI" == "active" ]; then echo -e "${GREEN}РАБОТАЕТ${NC}"; else echo -e "${RED}ОСТАНОВЛЕН${NC}"; fi)
        echo -e "${BLUE}Текущий статус: [${STATUS_DISPLAY}]${NC}"
        # Путь панели у 3x-ui случайный, и держать его в голове невозможно.
        # Строки нет, если адрес собрать не удалось: панель не установлена или
        # домен ещё не известен.
        PANEL_URL=$(xui_panel_url)
        [ -n "$PANEL_URL" ] && echo -e "${BLUE}Панель:         ${NC}${CYAN}${PANEL_URL}${NC}"
        # Учётки печатаются здесь, а не в главном меню: то открывается при
        # каждом входе по SSH, и его скриншот лежит в публичном README.
        XUI_USER=$(xui_admin_user); XUI_PASS=$(xui_admin_pass)
        if [ -n "$XUI_USER" ] || [ -n "$XUI_PASS" ]; then
            # printf, а не echo -e: цвета разворачиваются в формате, а сами
            # значения приходят аргументами и escape-последовательностями не
            # считаются. Пароль с обратным слэшем печатается как есть.
            printf "${BLUE}Логин:          ${NC}${YELLOW}%s${NC}    ${BLUE}пароль: ${NC}${YELLOW}%s${NC}\n" \
                "${XUI_USER:-—}" "${XUI_PASS:-—}"
        elif [ "$STATUS_XUI" == "active" ]; then
            # Подсказка только при работающей панели: на чистом сервере учёток
            # ещё неоткуда взяться, и строка была бы шумом.
            echo -e "${BLUE}Логин и пароль: ${NC}не записаны — пункт 7"
        fi
        echo -e "${BLUE}------------------------------------------------------${NC}"

        echo -e "${GREEN}1) 📥  Установить X-UI Pro (nginx | SSL | Clash | диагностика)${NC}"
        echo -e "${YELLOW}2) 🩹  Применить патч (обновить без изменения БД)${NC}"
        echo -e "${CYAN}3) 🛡️   AdGuard Home (опционально)${NC}"
        echo -e "${CYAN}4) 💾  Бэкап и восстановление (создать | список | вернуть)${NC}"
        echo -e "${YELLOW}5) 🚥  Управление сервисом (статус | старт | стоп | рестарт)${NC}"
        echo -e "${CYAN}6) 🖥️   Запустить панель X-UI (команда x-ui)${NC}"
        echo -e "${CYAN}7) 🔑  Учётные данные панели (показать | записать)${NC}"
        # Удаление уехало с 7 на 8 из-за нового пункта. Сдвиг безопасен именно
        # в эту сторону: кто по привычке нажмёт 7, попадёт на экран учёток, а
        # не на снос панели. Обратный порядок был бы недопустим.
        echo -e "${RED}8) 🗑️   Удалить X-UI Pro полностью${NC}"
        echo -e "${RED}X) 🔙  Назад в главное меню${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"

        read -p "Ваш выбор [1-8, X]: " choice
        echo ""

        case $choice in
            1) install_xui_pro ;;
            2) patch_xui_pro ;;
            3) manage_adguard ;;
            4) manage_backup ;;
            5)
                manage_service_status_restart $SERVICE_NAME
                ;;
            6)
                echo -e "${YELLOW}Запускаю X-UI... (Для выхода из X-UI используйте Ctrl+C)${NC}"
                if command -v x-ui &> /dev/null; then
                    x-ui
                elif [ -f "/usr/bin/x-ui" ]; then
                    /usr/bin/x-ui
                elif [ -f "/usr/local/bin/x-ui" ]; then
                    /usr/local/bin/x-ui
                else
                    echo -e "${RED}Команда x-ui не найдена.${NC}"
                fi
                read -p "Нажмите Enter для возврата в меню..."
                ;;
            7) manage_xui_credentials ;;
            8) uninstall_xui_pro ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
        esac
    done
}
manage_xui_service
