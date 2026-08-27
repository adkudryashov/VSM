#!/bin/bash
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh" || {
    echo "Не найдена lib/common.sh — переустановите VSM: bash install.sh"; exit 1; }

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
# ======================================================================
# СМЕНА ПАРОЛЯ ПАНЕЛИ — В САМОЙ ПАНЕЛИ И СРАЗУ У НАС
#
# До этого пункта операций было две, и они были не связаны: пароль меняют
# командой панели, а записную книжку VSM правят отдельно. Забыть вторую очень
# легко — и узнаёшь об этом не сразу, а когда понадобится вход, потому что
# панель хранит bcrypt-хэш и прочитать пароль обратно нельзя ничем.
#
# Владелец упёрся в это на приёмке 27.08.2026: установщик 3x-ui печатает
# случайные логин и пароль ОДИН РАЗ в середине многоминутного вывода, VSM их не
# подхватывал, и через несколько часов войти было нечем. Логин удалось достать
# из базы панели, пароль — нет.
#
# Здесь оба действия слиты в одно и проверяются фактом: сменилось ли значение в
# базе панели. Кода возврата чужой команды мало — это правило проекта.
# ======================================================================
function xui_change_password {
    local db=/etc/x-ui/x-ui.db
    local bin=/usr/local/x-ui/x-ui

    if [ ! -x "$bin" ]; then
        echo -e "${RED}❌ Панель не установлена — менять нечего.${NC}"
        return 1
    fi

    # sqlite3 нужен для главного здесь — проверки ФАКТОМ, что пароль в базе
    # панели действительно сменился. Без него смена сработает, но подтвердить
    # её будет нечем, а «кода возврата мало» — правило проекта, оплаченное
    # тремя дефектами. Ставим молча: пакет крошечный и без зависимостей.
    ensure_packages "sqlite3:sqlite3" >/dev/null 2>&1 || true

    # Логин берём из базы панели, а не из нашей записной книжки: книжку могли
    # не заполнить или заполнить неверно, а база — источник правды.
    local cur_user=""
    if command -v sqlite3 >/dev/null 2>&1 && [ -r "$db" ]; then
        cur_user="$(sqlite3 "$db" "select username from users limit 1;" 2>/dev/null)"
    fi
    [ -n "$cur_user" ] || cur_user="$(xui_admin_user)"
    if [ -z "$cur_user" ]; then
        echo -e "${YELLOW}Логин определить не удалось — введите его вручную.${NC}"
        IFS= read -r -p "Логин панели: " cur_user
        [ -n "$cur_user" ] || { echo -e "${BLUE}Пусто — отменено.${NC}"; return 1; }
    else
        echo -e "${BLUE}Логин панели: ${YELLOW}${cur_user}${NC}"
        local keep
        IFS= read -r -p "$(echo -e "${BLUE}Оставить этот логин? [Y/n]: ${NC}")" keep
        case "$keep" in
            [Nn]*) IFS= read -r -p "Новый логин: " cur_user
                   [ -n "$cur_user" ] || { echo -e "${BLUE}Пусто — отменено.${NC}"; return 1; } ;;
        esac
    fi

    # -s: набор не должен попадать в запись сессии и в скроллбэк. Дважды —
    # опечатка в пароле, который больше нигде не прочитать, стоит доступа к
    # панели.
    local p1 p2
    IFS= read -rs -p "Новый пароль: " p1; echo
    if [ -z "$p1" ]; then
        echo -e "${BLUE}Пусто — отменено, пароль не менялся.${NC}"
        return 1
    fi
    IFS= read -rs -p "Повторите пароль: " p2; echo
    if [ "$p1" != "$p2" ]; then
        echo -e "${RED}❌ Пароли не совпали — ничего не менялось.${NC}"
        return 1
    fi

    # Отпечаток «до»: по нему и убедимся, что панель приняла новый пароль.
    local hash_before=""
    if command -v sqlite3 >/dev/null 2>&1 && [ -r "$db" ]; then
        hash_before="$(sqlite3 "$db" "select password from users limit 1;" 2>/dev/null)"
    fi

    if ! "$bin" setting -username "$cur_user" -password "$p1" >/dev/null 2>&1; then
        echo -e "${RED}❌ Панель отказалась менять учётные данные.${NC}"
        echo -e "${YELLOW}   Проверьте вручную: ${bin} setting -show${NC}"
        return 1
    fi

    # Проверка ФАКТОМ, а не кодом возврата: хэш в базе обязан стать другим.
    if [ -n "$hash_before" ]; then
        local hash_after
        hash_after="$(sqlite3 "$db" "select password from users limit 1;" 2>/dev/null)"
        if [ "$hash_after" = "$hash_before" ]; then
            echo -e "${RED}❌ Пароль в базе панели не изменился — смена не состоялась.${NC}"
            echo -e "${YELLOW}   Прежний пароль по-прежнему действует.${NC}"
            return 1
        fi
    else
        # Молчать об этом нельзя: человек уйдёт уверенным, что пароль сменён,
        # а мы этого не проверяли.
        echo -e "${YELLOW}⚠  Подтвердить смену по базе панели не удалось (нет sqlite3).${NC}"
        echo -e "${YELLOW}   Проверьте входом, прежде чем закрывать сессию.${NC}"
    fi

    # Записываем ТОЛЬКО после подтверждённой смены. Иначе в книжке лежал бы
    # пароль, которого панель не знает, — хуже, чем пустая книжка: пустую видно.
    if xui_credentials_save "$cur_user" "$p1"; then
        echo -e "${GREEN}✓ Пароль сменён и записан в $XUI_CONF_FILE (права 600).${NC}"
    else
        echo -e "${YELLOW}⚠  Пароль в панели сменён, но записать его не удалось.${NC}"
        echo -e "${YELLOW}   Запомните его сами: прочитать обратно нельзя, панель хранит хэш.${NC}"
    fi

    systemctl restart x-ui >/dev/null 2>&1 || true
    sleep 2
    if systemctl is-active --quiet x-ui; then
        echo -e "${GREEN}✓ Панель перезапущена и работает.${NC}"
    else
        echo -e "${RED}❌ Панель не поднялась — journalctl -u x-ui -n 30${NC}"
        return 1
    fi
    return 0
}

function warn_telemt_after_panel_change {
    if [ -f /etc/telemt/telemt.toml ]; then
        echo -e "\n${YELLOW}❗  На сервере установлен стек telemt.${NC}"
        echo -e "${YELLOW}    Панель могла перегенерировать свои nginx-конфиги."
        echo -e "    Проверь маскировку: главное меню -> 'Стек telemt / MTProto'"
        echo -e "    -> 'Статус и диагностика'. При сбое — 'Восстановить маскировку'.${NC}"
    fi
}

function install_xui_pro {
    clear 2>/dev/null
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}          📥  УСТАНОВКА X-UI PRO (3x-ui-pro) 📥        ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}Устанавливает: 3x-ui, nginx, SSL (Let's Encrypt), Clash-подписку, диагностику сети.${NC}"
    echo -e "${YELLOW}Нужны два домена/поддомена: один для панели, другой для REALITY.${NC}"
    echo ""

    # Панель уже стоит — это переустановка, а она уносит базу инбаундов.
    #
    # Здесь не было ни слова. Пункт назывался просто «Установить», описание
    # перечисляло, что ставится, и ни экран, ни подпись не сообщали, что
    # существующая панель будет стёрта вместе со всеми клиентами. Рядом, на
    # соседней клавише, живёт «Применить патч» — он-то базу и сохраняет.
    # То есть промах по клавише уносил всех клиентов молча, а верный пункт
    # был в одном нажатии.
    #
    # Подтверждение словом, а не [y/N]: цена ошибки — все конфигурации
    # пользователей, восстановить их можно только из бэкапа, которого может и
    # не быть.
    if [ -d /etc/x-ui ]; then
        echo -e "${RED}❗  3x-ui на сервере УЖЕ УСТАНОВЛЕНА.${NC}"
        echo -e "${RED}    Установка заново стирает базу инбаундов: все клиенты,${NC}"
        echo -e "${RED}    их ключи и подписки исчезнут.${NC}"
        echo ""
        echo -e "${C_DESC}    Обновить панель, сохранив базу, — пункт 2 «Применить патч».${NC}"
        echo -e "${C_DESC}    Снять копию базы перед этим — пункт 4 «Бэкап».${NC}"
        echo ""
        local wipe_confirm
        read -r -p "$(echo -e "${RED}Введите СТЕРЕТЬ, чтобы переустановить с потерей базы: ${NC}")" wipe_confirm
        if [ "$wipe_confirm" != "СТЕРЕТЬ" ]; then
            echo -e "${BLUE}Отменено. Панель и её база не тронуты.${NC}"
            read -p "Нажмите Enter для продолжения..."
            return
        fi
        echo ""
    fi

    # Автоопределение доменов больше не предлагается. Апстрим удалил его
    # коммитом 18a2e01 «delete autodomain»: разбор -auto_domain снят, а вместе
    # с ним и подстановка вида <ip>.cdn-one.org — wildcard-DNS автора, которого
    # больше нет. Восстановить нечем.
    #
    # Молчать об этом было нельзя. Разбор аргументов у автора заканчивается
    # веткой `*) shift 1`, то есть неизвестный флаг проглатывается без слова:
    # мы передали бы -auto_domain y, домены остались бы пустыми, и установщик
    # ушёл бы в свой `while [[ -z $domain ]]; do read -r domain; done`. С
    # терминалом человек, выбравший «без ручного ввода», получил бы английский
    # запрос ручного ввода; без TTY read возвращается мгновенно и пустым, и
    # цикл занимает ядро навсегда.
    local xui_args=()
    read -p "Домен панели (например panel.example.com): " subdomain
    read -p "Домен для REALITY (другой домен/поддомен): " reality_domain

    # Отказываем сразу, а не «просто не добавляем флаг». Прежний код на пустой
    # ответ молча опускал аргумент и приводил в тот же бесконечный цикл у
    # автора. Правило то же, что в ask_domains меню telemt.
    if [ -z "$subdomain" ] || [ -z "$reality_domain" ]; then
        echo -e "${RED}❌ Оба домена обязательны — установщику их взять неоткуда.${NC}"
        read -p "Нажмите Enter для продолжения..."
        return
    fi
    if [ "$subdomain" == "$reality_domain" ]; then
        echo -e "${RED}❌ Домены должны быть разными, иначе nginx не примет конфиг.${NC}"
        read -p "Нажмите Enter для продолжения..."
        return
    fi
    xui_args+=(-subdomain "$subdomain" -reality_domain "$reality_domain")

    read -p "Версия 3x-ui (Enter = последняя): " version
    [ -n "$version" ] && xui_args+=(-version "$version")

    echo -e "${CYAN}>>> Запуск установки 3x-ui-pro...${NC}"

    # Загрузка, сверка отпечатка и снятие проверки CPU — в общей
    # xui_installer_fetch. Раньше этот блок жил здесь, и проверка CPU снималась
    # только тут: удаление панели и установка стека запускали тот же файл без
    # правки и падали на хостерах с эмулированным процессором.
    local installer; installer=$(mktemp /tmp/vsm-xui.XXXXXX.sh)
    if ! xui_installer_fetch "$XUI_PRO_REPO/x-ui-latest.sh" "$installer"; then
        read -p "Нажмите Enter для продолжения..."
        return
    fi
    if [ "${UPSTREAM_CHANGED:-0}" -ne 0 ]; then
        read -p "$(echo -e "${YELLOW}Enter — продолжить установку изменившимся скриптом...${NC}")"
    fi
    bash "$installer" "${xui_args[@]}"
    rm -f "$installer"
    warn_telemt_after_panel_change
    read -p "Нажмите Enter для продолжения..."
}

function patch_xui_pro {
    echo -e "${CYAN}>>> Применение патча к текущей установке (без изменения БД)...${NC}"
    # Отдельной сверкой, без снятия проверки CPU: в x-ui-patch.sh check_cpu нет
    # вовсе — проверено по тексту. Скачиваем ради отпечатка, а запускает
    # run_remote_script своей копией: два скачивания дешевле, чем ветвление в
    # общей функции ради одного вызова.
    local probe; probe=$(mktemp /tmp/vsm-xui-patch.XXXXXX.sh)
    if curl -fsSL --max-time 60 "$XUI_PRO_REPO/x-ui-patch.sh" -o "$probe" && [ -s "$probe" ]; then
        upstream_fingerprint "$XUI_PRO_REPO/x-ui-patch.sh" "$probe" || \
            read -p "$(echo -e "${YELLOW}Enter — продолжить изменившимся скриптом...${NC}")"
    fi
    rm -f "$probe"
    run_remote_script "$XUI_PRO_REPO/x-ui-patch.sh"
    warn_telemt_after_panel_change
    read -p "Нажмите Enter для продолжения..."
}

function manage_adguard {
    while true; do
        clear 2>/dev/null
        echo -e "${CYAN}--- 🔒  ADGUARD HOME (DNS-over-HTTPS + блокировка рекламы) ---${NC}"
        echo -e "${YELLOW}Ставится на домен панели, без отдельного домена и портов (через 443).${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        ui_item        "1" "📥" "Установить или обновить" "AdGuard Home на домене панели, через 443"
        ui_danger_item "2" "Удалить"                "Снимает AdGuard и его блок в nginx"
        ui_item "X" "🔙" "Назад"
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
        clear 2>/dev/null
        echo -e "${CYAN}--- 💾  БЭКАП / ВОССТАНОВЛЕНИЕ X-UI PRO ---------------${NC}"
        ui_item        "1" "📦" "Создать бэкап"   "База панели и её настройки"
        ui_item        "2" "📋" "Список бэкапов"   "Что уже снято и когда"
        ui_danger_item "3" "Восстановить"    "Переписывает текущую базу панели"
        ui_item "X" "🔙" "Назад"
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
        clear 2>/dev/null
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
        ui_item "1" "📝" "Записать или обновить" "VSM запомнит их: панель хранит пароль хэшем"
        ui_item "2" "🔐" "Сменить пароль панели" "Меняет В ПАНЕЛИ и сразу запоминает здесь"
        ui_item "3" "🧹" "Стереть запись"        "Только у нас; пароль в панели не меняется"
        ui_item "X" "🔙" "Назад"
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
                xui_change_password
                read -p "Нажмите Enter для продолжения..."
                ;;
            3)
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
    echo -e "${RED}❗  Будут удалены:"
    echo -e "      • панель 3x-ui-pro с базой инбаундов и пользователей"
    echo -e "      • nginx целиком: пакет вычищается (purge), каталог /etc/nginx удаляется"
    echo -e "      • /var/www/html, страницы подписок и диагностики${NC}"
    echo -e "${GREEN}    Сертификаты Let's Encrypt в /etc/letsencrypt НЕ удаляются.${NC}"
    if [ -f /etc/telemt/telemt.toml ]; then
        echo -e "\n${RED}❗  На сервере установлен стек telemt, и удаление панели его сломает:"
        echo -e "    вместе с /etc/nginx исчезнет conf.d/telemt-mask.conf, вместе с"
        echo -e "    /var/www/html — webroot маскировки, а за остановленным nginx"
        echo -e "    systemd унесёт и telemt (Requires=nginx.service)."
        echo -e "    Панель придётся ставить заново и прогонять «Восстановить маскировку».${NC}"
    fi
    read -p "$(echo -e "${RED}Введите УДАЛИТЬ для подтверждения: ${NC}")" confirm
    if [ "$confirm" == "УДАЛИТЬ" ]; then
        # Снимаем apt-mark hold, поставленный пересборкой nginx с OpenSSL 3.5.
        #
        # Без этого удаление не проходит: установщик автора делает purge nginx,
        # а захолженный nginx-full зависит от nginx, и apt отказывается решать
        # конфликт — `apt-get -s purge nginx nginx-common` возвращает 100 с
        # «Это может быть вызвано зафиксированными пакетами». Проверено на
        # стенде после пересборки. То есть один пункт меню молча ломал другой,
        # и связь эта нигде не была записана.
        #
        # Снимать безопасно ровно здесь: nginx сейчас будет удалён целиком,
        # защищать пересобранный бинарник от перезаписи больше не от чего.
        local held; held=$(apt-mark showhold 2>/dev/null | grep -E '^nginx' | tr '\n' ' ')
        if [ -n "$held" ]; then
            echo -e "${YELLOW}>>> Снимаю фиксацию пакетов после пересборки: ${held}${NC}"
            # shellcheck disable=SC2086
            apt-mark unhold $held >/dev/null 2>&1
            local still; still=$(apt-mark showhold 2>/dev/null | grep -cE '^nginx')
            if [ "${still:-0}" -ne 0 ]; then
                echo -e "${RED}❗  Фиксация снялась не полностью — удаление nginx может не пройти.${NC}"
            fi
        fi
        # Через xui_installer_fetch, а не run_remote_script: это тот же файл
        # установщика, и check_cpu в нём срабатывает независимо от -uninstall.
        # Прежний вызов правку не применял, поэтому на хостере с эмулированным
        # процессором удаление не выполнялось вовсе: скрипт выходил с exit 1 до
        # ветки удаления, на экране появлялась чужая английская ошибка, а код
        # возврата никто не смотрел. Именно на таких хостерах патч и нужен.
        local remover; remover=$(mktemp /tmp/vsm-xui-rm.XXXXXX.sh)
        if xui_installer_fetch "$XUI_PRO_REPO/x-ui-latest.sh" "$remover"; then
            bash "$remover" -uninstall y
            local rc=$?
            rm -f "$remover"
            if [ "$rc" -ne 0 ]; then
                echo -e "${RED}❌ Установщик вернул код ${rc} — панель могла остаться на месте.${NC}"
                echo -e "${YELLOW}   Проверьте: systemctl status x-ui${NC}"
            fi
        fi
    else
        echo -e "${BLUE}Отменено.${NC}"
    fi
    read -p "Нажмите Enter для продолжения..."
}

function manage_xui_service {
    local SERVICE_NAME=$XUI_SERVICE
    while true; do
        clear 2>/dev/null
        ui_title "📊  ПАНЕЛЬ X-UI (3x-ui-pro)"

        STATUS_XUI=$(get_service_status $SERVICE_NAME)
        # Текст и цвет раздельно: сцепленная строка не выравнивается, ui_pad
        # посчитал бы escape-коды за символы.
        if [ "$STATUS_XUI" == "active" ]; then
            ST_TXT="РАБОТАЕТ"; ST_COL="$C_OK"
        else
            ST_TXT="ОСТАНОВЛЕН"; ST_COL="$C_DANGER"
        fi
        echo ""
        echo -e "   ${C_NAME}$(ui_pad '🚥  Статус' 20)${NC}${ST_COL}${ST_TXT}${NC}"
        # Путь панели у 3x-ui случайный, и держать его в голове невозможно.
        # Строки нет, если адрес собрать не удалось: панель не установлена или
        # домен ещё не известен.
        PANEL_URL=$(xui_panel_url)
        [ -n "$PANEL_URL" ] && ui_kv '🌐  Панель' "$PANEL_URL" 20
        # Учётки печатаются здесь, а не в главном меню: то открывается при
        # каждом входе по SSH, и его скриншот лежит в публичном README.
        XUI_USER=$(xui_admin_user); XUI_PASS=$(xui_admin_pass)
        if [ -n "$XUI_USER" ] || [ -n "$XUI_PASS" ]; then
            # printf, а не echo -e: цвета разворачиваются в формате, а сами
            # значения приходят аргументами и escape-последовательностями не
            # считаются. Пароль с обратным слэшем печатается как есть.
            #
            # Значения жирным, а не серым: серый пароль нечитаем на светлом
            # терминале, и оформление отняло бы функцию там, где она важнее
            # всего.
            printf "   %b%s%b%b%s%b\n" "$C_NAME" "$(ui_pad '👤  Логин' 20)" "$NC" \
                "$C_SECRET" "${XUI_USER:-—}" "$NC"
            printf "   %b%s%b%b%s%b\n" "$C_NAME" "$(ui_pad '🔑  Пароль' 20)" "$NC" \
                "$C_SECRET" "${XUI_PASS:-—}" "$NC"
        elif [ "$STATUS_XUI" == "active" ]; then
            # Подсказка только при работающей панели: на чистом сервере учёток
            # ещё неоткуда взяться, и строка была бы шумом.
            ui_kv '🔑  Учётные данные' 'не записаны — пункт 3' 20
        fi

        echo ""
        ui_section "УСТАНОВКА И ОБНОВЛЕНИЕ"
        ui_item "1" "📥" "Установить"         "С нуля: nginx, SSL, подписка. Поверх старой — со стиранием базы"
        ui_item "2" "🩹" "Применить патч"     "Обновление без изменения базы инбаундов"
        echo ""
        ui_section "ЭКСПЛУАТАЦИЯ"
        ui_item "3" "🔑" "Учётные данные"     "Показать или записать логин и пароль"
        ui_item "4" "💾" "Бэкап"              "Создать, посмотреть список, восстановить"
        ui_item "5" "🚥" "Управление службой" "Статус, старт, стоп, рестарт"
        ui_item "6" "💻" "Открыть панель"     "Штатное меню апстрима (команда x-ui)"
        echo ""
        ui_section "ДОПОЛНИТЕЛЬНО"
        ui_item "7" "🔒" "AdGuard Home"       "DNS-over-HTTPS и блокировка рекламы"
        echo ""
        # Удаление уехало с 7 на 8 из-за нового пункта. Сдвиг безопасен именно
        # в эту сторону: кто по привычке нажмёт 7, попадёт на экран учёток, а
        # не на снос панели. Обратный порядок был бы недопустим.
        ui_danger_item "8" "Удалить X-UI Pro" "Панель, база и nginx целиком"
        ui_item "X" "🔙" "Назад"
        echo ""

        read -p "Ваш выбор [1-8, X]: " choice
        echo ""

        case $choice in
            1) install_xui_pro ;;
            2) patch_xui_pro ;;
            3) manage_xui_credentials ;;
            4) manage_backup ;;
            5)
                manage_service_status_restart $SERVICE_NAME
                ;;
            6)
                echo -e "${YELLOW}Запускаю X-UI... (Для выхода из X-UI используйте Ctrl+C)${NC}"
                if have_cmd x-ui; then
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
            7) manage_adguard ;;
            8) uninstall_xui_pro ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
        esac
    done
}
manage_xui_service
