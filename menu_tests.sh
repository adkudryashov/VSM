#!/bin/bash
source /usr/local/bin/_config_and_utils.sh

# ----------------------------------------------------------------------
# ТЕСТЫ И СКАНЕР (Вынесенный блок)
# ----------------------------------------------------------------------

function prepare_scanner {
    SCANNER_DIR="/root/scanner"
    SCANNER_BIN="$SCANNER_DIR/RealiTLScanner"
    MMDB_FILE="$SCANNER_DIR/Country.mmdb"

    # Создаем папку, если ее нет
    if [ ! -d "$SCANNER_DIR" ]; then
        mkdir -p "$SCANNER_DIR"
    fi

    # Проверка бинарника (XTLS)
    if [ ! -f "$SCANNER_BIN" ]; then
        echo -e "${YELLOW}>>> Сканер не найден. Загрузка RealiTLScanner (XTLS)...${NC}"
        wget -qO "$SCANNER_BIN" "https://github.com/XTLS/RealiTLScanner/releases/latest/download/RealiTLScanner-linux-64"
        chmod +x "$SCANNER_BIN"
    fi

    # Проверка GeoIP базы (Loyalsoldier)
    if [ ! -f "$MMDB_FILE" ]; then
        echo -e "${YELLOW}>>> База GeoIP не найдена. Загрузка Country.mmdb (Loyalsoldier)...${NC}"
        wget -qO "$MMDB_FILE" "https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb"
    fi
    
    # Указываем путь к бинарнику для функции run_scanner
    SCANER_PATH="$SCANNER_BIN"
    cd "$SCANNER_DIR" || return
}

function run_scanner {
    # Сначала проверяем и загружаем файлы
    prepare_scanner

    PARAMS=""
    
    echo -e "\n${CYAN}>>> ЗАПУСК Realitls Scaner${NC}"
    echo -e "${YELLOW}Доступные параметры:${NC}"
    echo "  1) 📄  -in (Файл со списком IP/CIDR)"
    echo "  2) 🎯  -addr (Один IP/CIDR или домен)"
    echo "  3) 🌐  -url (URL со списком доменов)"
    echo -e " ${RED}X) ❌  Отмена${NC}"
    
    read -p "Выберите метод ввода [1-3, X]: " method

    case $method in
        1) read -p "Путь к файлу (-in): " INPUT_VAL;
            PARAMS+=" -in $INPUT_VAL" ;;
        2) read -p "IP/Домен (-addr): " INPUT_VAL; PARAMS+=" -addr $INPUT_VAL" ;;
        3) read -p "URL (-url): " INPUT_VAL; PARAMS+=" -url $INPUT_VAL" ;;
        [Xx]) echo -e "${RED}Отмена запуска.${NC}"; return ;;
        *) echo -e "${RED}❌ Неверный ввод.${NC}"; return ;;
    esac

    read -p "Порт (default 443): " PORT_VAL
    if [[ ! -z "$PORT_VAL" ]]; then PARAMS+=" -port $PORT_VAL"; fi

    read -p "Потоки (default 2): " THREAD_VAL
    if [[ ! -z "$THREAD_VAL" ]]; then PARAMS+=" -thread $THREAD_VAL"; fi

    read -p "Таймаут (default 10): " TIMEOUT_VAL
    if [[ ! -z "$TIMEOUT_VAL" ]]; then PARAMS+=" -timeout $TIMEOUT_VAL"; fi

    read -p "Файл вывода (default out.csv): " OUTPUT_VAL
    if [[ ! -z "$OUTPUT_VAL" ]]; then PARAMS+=" -out $OUTPUT_VAL"; fi
    
    read -p "Использовать IPv6 (-46)? [y/N]: " IPV6_VAL
    if [[ "$IPV6_VAL" =~ ^[Yy]$ ]]; then PARAMS+=" -46"; fi

    read -p "Подробный вывод (-v)? [y/N]: " VERBOSE_VAL
    if [[ "$VERBOSE_VAL" =~ ^[Yy]$ ]]; then PARAMS+=" -v"; fi

    echo -e "\n${YELLOW}ЗАПУСК КОМАНДЫ:${NC} $SCANER_PATH $PARAMS"
    $SCANER_PATH $PARAMS
    echo -e "\n${GREEN}Scaner завершил работу.${NC}"
}
# ----------------------------------------------------------------------
# CENSORCHECK (своя реализация, censorcheck.sh в этом же репозитории)
# ----------------------------------------------------------------------
# Раньше здесь скачивался и выполнялся от root скрипт с чужого домена, а его
# радар ТСПУ работал на ключе RIPE Atlas автора — при явной просьбе автора
# этот ключ в сторонних проектах не использовать. Мы расходовали чужую квоту,
# и отвалиться проверка могла в любой момент не по нашей воле.
#
# Своя реализация: три уровня наблюдения, каждый деградирует по отдельности и
# честно сообщает, что именно не проверено. Ключ RIPE — свой, задаётся здесь же.
CENSORCHECK_SCRIPT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/censorcheck.sh"

# Проба RIPE Atlas — источник кредитов для радара ТСПУ. Живёт рядом, потому что
# без кредитов третий уровень censorcheck просто не запускается, и объяснять
# это пользователю нужно там же, где он видит отказ.
ATLAS_SCRIPT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/atlas-probe.sh"

function run_atlas_probe {
    if [ ! -f "$ATLAS_SCRIPT" ]; then
        echo -e "${RED}❌ Не найден $ATLAS_SCRIPT — обновите VSM (install.sh).${NC}"
        read -p "Нажмите Enter..."; return
    fi
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}   📡  ПРОБА RIPE ATLAS  📡                           ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "    Состояние: [$(bash "$ATLAS_SCRIPT" --line)]"
        echo -e "${YELLOW}    Радар ТСПУ стоит 200 кредитов за замер. Подключённая"
        echo -e "    проба приносит около 21 600 кредитов в сутки.${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "${GREEN}1) 📊  Состояние и баланс кредитов${NC}"
        echo -e "${GREEN}2) 📡  Разместить пробу на этом сервере${NC}"
        echo -e "${CYAN}3) 🔑  Показать ключ для регистрации${NC}"
        echo -e "${RED}4) 🗑️   Удалить пробу${NC}"
        echo -e "${RED}X) 🔙  Назад${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        # "|| return" по той же причине, что и в подменю censorcheck ниже.
        read -p "Выбор: " ap_choice || return
        case $ap_choice in
            1) bash "$ATLAS_SCRIPT" --status;  read -p "Нажмите Enter..." ;;
            2) bash "$ATLAS_SCRIPT" --install; read -p "Нажмите Enter..." ;;
            3) bash "$ATLAS_SCRIPT" --key;     read -p "Нажмите Enter..." ;;
            4) bash "$ATLAS_SCRIPT" --remove;  read -p "Нажмите Enter..." ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

function run_censorcheck {
    if [ ! -f "$CENSORCHECK_SCRIPT" ]; then
        echo -e "${RED}❌ Не найден $CENSORCHECK_SCRIPT — обновите VSM (install.sh).${NC}"
        read -p "Нажмите Enter..."; return
    fi

    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}   🧪  ПРОВЕРКА ДОСТУПНОСТИ ИЗ РОССИИ  🧪             ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        local key_state="${RED}НЕ ЗАДАН${NC}"
        [ -f /etc/vsm/censorcheck.conf ] && grep -q '^RIPE_API_KEY=.\+' /etc/vsm/censorcheck.conf \
            && key_state="${GREEN}ЗАДАН${NC}"
        echo -e "    Ключ RIPE Atlas: [$key_state]"
        echo -e "    Проба Atlas:     [$(bash "$ATLAS_SCRIPT" --line 2>/dev/null || echo "?")]"
        echo -e "${YELLOW}    Без ключа работают локальные проверки и датацентровые"
        echo -e "    узлы; радар ТСПУ в домашних сетях требует ключа и кредитов.${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "${GREEN}1) 🎯  Проверить свой стек (домены и порты из конфига)${NC}"
        echo -e "${GREEN}2) 🌐  Проверить произвольный домен${NC}"
        echo -e "${CYAN}3) 🔑  Задать ключ RIPE Atlas${NC}"
        echo -e "${CYAN}4) 📡  Проба RIPE Atlas (кредиты для радара)${NC}"
        echo -e "${RED}X) 🔙  Назад${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        # "|| return" обязателен: при закрытом stdin (пайп, оборванный
        # терминал, запуск не из tty) read возвращается мгновенно и с пустым
        # значением. Без этой проверки цикл уходит в раскрутку вхолостую и
        # занимает ядро целиком — поймано при прогоне меню через пайп.
        read -p "Выбор: " cc_choice || return

        local tg="no"
        case $cc_choice in
            1|2)
                read -p "$(echo -e "${CYAN}Отправить отчёт в Telegram-бота? [y/N]: ${NC}")" cc_tg
                [[ "$cc_tg" =~ ^[Yy]$ ]] && tg="yes"
                ;;
        esac

        case $cc_choice in
            1) bash "$CENSORCHECK_SCRIPT" --stack "$tg"; read -p "Нажмите Enter..." ;;
            2)
                # -e (readline) — чтобы вставленный домен не приезжал
                # обёрнутым в escape-последовательности bracketed paste.
                read -e -p "Домен для проверки: " cc_dom
                if [ -z "$cc_dom" ]; then
                    echo -e "${RED}Домен не задан.${NC}"; sleep 1
                else
                    bash "$CENSORCHECK_SCRIPT" --domain "$cc_dom" "$tg"
                    read -p "Нажмите Enter..."
                fi
                ;;
            3) bash "$CENSORCHECK_SCRIPT" --set-key; read -p "Нажмите Enter..." ;;
            4) run_atlas_probe ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

# ----------------------------------------------------------------------
# DPI DETECTOR & SNI SCAN
# ----------------------------------------------------------------------

function run_dpi_detector {
    echo -e "\n${CYAN}>>> Подготовка DPI Detector (через Docker)...${NC}"
    
    # 1. Docker. ensure_packages ставит и проверяет по факту: прежний вариант
    # печатал «Docker успешно установлен!» безусловно, а `docker run` следом
    # падал с command not found.
    if ! ensure_packages "docker.io:docker"; then
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    # 2. Демон должен быть поднят — сам пакет этого не гарантирует
    if ! systemctl is-active --quiet docker; then
        echo -e "${YELLOW}>>> Запускаю службу docker...${NC}"
        sudo systemctl enable --now docker 2>/dev/null || true
        sleep 2
    fi
    if ! sudo docker info &> /dev/null; then
        echo -e "${RED}❌ Docker установлен, но демон не отвечает.${NC}"
        echo -e "${YELLOW}   Проверьте: systemctl status docker${NC}"
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    # 3. Запуск контейнера
    echo -e "${GREEN}✅ Запуск DPI Detector...${NC}"
    echo -e "${YELLOW}(Образ обновится автоматически. Для выхода нажмите Ctrl+C)${NC}"
    sleep 1

    # --rm удаляет контейнер после закрытия (не копит мусор)
    # -it запускает в интерактивном режиме с нормальным отображением меню
    # --pull=always всегда проверяет и качает свежую версию перед запуском
    sudo docker run --rm -it --pull=always ghcr.io/runnin4ik/dpi-detector:latest
    
    echo -e "\n${BLUE}------------------------------------------------------${NC}"
    read -p "Нажмите Enter для возврата в меню..."
}

function run_sni_scan {
    echo -e "\n${CYAN}>>> Подготовка SNI Scan...${NC}"
    
    # 1. Проверка Python3
    if ! ensure_packages python3 git; then
        read -p "Нажмите Enter для возврата в меню..."
        return
    fi

    local DIR="/root/sni-scan"
    
    # 2. Клонирование или обновление
    if [ ! -d "$DIR" ]; then
        echo -e "${YELLOW}Клонирование репозитория...${NC}"
        git clone https://github.com/dewil/sni-scan.git "$DIR"
    else
        echo -e "${YELLOW}Обновление файлов...${NC}"
        cd "$DIR" && git pull -q
    fi

    cd "$DIR" || return

    # 3. Запрос параметров у пользователя
    echo -e "${BLUE}------------------------------------------------------${NC}"
    read -p "Укажите маску подсети для скана [по умолчанию 24]: " subnet_mask
    subnet_mask=${subnet_mask:-24}

    # 4. Запуск
    echo -e "${GREEN}✅ Запуск сканирования сети (/$subnet_mask)...${NC}"
    echo -e "${YELLOW}(Отчет будет сохранен в $DIR/report.md)${NC}"
    echo -e "${YELLOW}(Для прерывания нажмите Ctrl+C)${NC}"
    sleep 1
    
    python3 sni-scan.py -m "$subnet_mask" -o report.md
    
    echo -e "\n${GREEN}✅ Готово! Результаты можно посмотреть в $DIR/report.md${NC}"
    echo -e "${BLUE}------------------------------------------------------${NC}"
    read -p "Нажмите Enter для возврата в меню..."
}
function run_tests_menu {
    while true; do
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}             🧪 МЕНЮ ТЕСТОВ СЕРВЕРА 🧪                ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${YELLOW}1) 🌍  IP region${NC}"
        echo -e "${YELLOW}2) 🧪  Доступность из РФ (DNS | датацентры | радар ТСПУ)${NC}"
        echo -e "${YELLOW}3) 🚀  Тест iPerf3 (серверы РФ)${NC}"
        echo -e "${YELLOW}4) 📊  YABS Benchmark${NC}"
        echo -e "${YELLOW}5) 🛡️   IPQuality (проверка IP на блокировки)${NC}"
        echo -e "${YELLOW}6) 📡  Параметры сервера (характеристики | скорость)${NC}"
        echo -e "${YELLOW}7) 💻  Тест процессора (sysbench)${NC}"
        echo -e "${YELLOW}8) 🔍  Realitls Scanner (поиск SNI)${NC}"
        echo -e "${YELLOW}9) 🕵️‍♂️  DPI Detector (анализ цензуры)${NC}"
        echo -e "${YELLOW}10) 🔍  SNI Scan (скан подсети)${NC}"
        echo -e "${RED}X) 🔙  Назад в главное меню${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        
        # См. комментарий в подменю censorcheck: без "|| return" закрытый stdin
        # превращает цикл меню в раскрутку вхолостую на полном CPU.
        read -p "Ваш выбор [1-10, X]: " choice || return
        echo ""

        case $choice in
            1)
                echo -e "${CYAN}>>> Запуск IP region...${NC}"
                run_remote_script "https://ipregion.vrnt.xyz"
                ;;
            2) run_censorcheck ;;
            3)
			# --- ПРОВЕРКА И УСТАНОВКА IPERF3 ---
ensure_packages iperf3 || echo -e "${YELLOW}   Тест скорости может не работать.${NC}"
                echo -e "${CYAN}>>> Тест iPerf3 (серверы РФ)...${NC}"
                run_remote_script "https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh"
                ;;
            4)
                echo -e "${CYAN}>>> Запуск YABS...${NC}"
                run_remote_script "https://yabs.sh" -4
                ;;
            5)
                echo -e "${CYAN}>>> Проверка IP сервера на блокировки зарубежными сервисами...${NC}"
                 run_remote_script "https://Check.Place" -EI
                ;;
            6)
                echo -e "${CYAN}>>> Параметры сервера (характеристики | скорость)...${NC}"
                run_remote_script "https://bench.sh"
                ;;

            7)
                echo -e "${CYAN}>>> Запуск теста на процессор...${NC}"
                # Проверка sysbench прямо перед запуском
    if ! ensure_packages sysbench; then
        read -p "Нажмите Enter для возврата в меню..."
        continue
    fi
				sysbench cpu run --threads=1
                ;;	
            8) run_scanner ;;
            9)
                run_dpi_detector
                ;;
            10)
                run_sni_scan
                ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}" ;;
        esac
        read -p "Нажмите Enter для продолжения..."
    done
}
run_tests_menu
