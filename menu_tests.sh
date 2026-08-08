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
# CENSORCHECK (запуск скрипта автора)
# ----------------------------------------------------------------------
# Censorcheck запускается напрямую с сайта автора одной командой: DNS,
# датацентры и радар ТСПУ в домашних сетях РФ.
CENSORCHECK_URL="censorcheck.tlab.pw"

function run_censorcheck {
    echo -e "${CYAN}>>> Запуск Censorcheck (геоблок + радар ТСПУ)...${NC}"
    echo -e "${YELLOW}Скрипт скачивается с $CENSORCHECK_URL и выполняется локально.${NC}\n"

    # Скачиваем отдельным шагом, а не конвейером в bash: в `wget | bash` код
    # возврата берётся от bash, и при недоступном адресе он получает пустой
    # ввод и выходит с нулём — сбой выглядел бы как успешная проверка.
    local tmp; tmp=$(mktemp /tmp/censorcheck.XXXXXX.sh) || return
    if ! wget -qO "$tmp" --timeout=20 "$CENSORCHECK_URL" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo -e "${RED}❌ Не удалось скачать скрипт проверки.${NC}"
        echo -e "${YELLOW}   Проверьте доступ к $CENSORCHECK_URL и повторите.${NC}"
        return
    fi
    bash "$tmp"
    rm -f "$tmp"
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
        echo -e "${YELLOW}5) 🔒   IPQuality (проверка IP на блокировки)${NC}"
        echo -e "${YELLOW}6) 📡  Параметры сервера (характеристики | скорость)${NC}"
        echo -e "${YELLOW}7) 💻  Тест процессора (sysbench)${NC}"
        echo -e "${YELLOW}8) 🔍  Realitls Scanner (поиск SNI)${NC}"
        echo -e "${YELLOW}9) 🔍  DPI Detector (анализ цензуры)${NC}"
        echo -e "${YELLOW}10) 🔍  SNI Scan (скан подсети)${NC}"
        echo -e "${RED}X) 🔙  Назад в главное меню${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"
        
        # "|| return" обязателен: при закрытом stdin (пайп, оборванный терминал,
        # запуск не из tty) read возвращается мгновенно и с пустым значением.
        # Без этой проверки цикл уходит в раскрутку вхолостую и занимает ядро
        # целиком — поймано при прогоне меню через пайп.
        read -p "Ваш выбор [1-10, X]: " choice || return
        echo ""

        case $choice in
            1)
                echo -e "${CYAN}>>> Запуск IP region...${NC}"
                # vernette/ipregion — оригинал проекта, vrnt.xyz его домен.
                # Форк Davoyan/ipregion рассматривался как замена и отклонён:
                # он отстаёт от оригинала (меньше звёзд, push на месяц старее,
                # нет флагов --json/--proxy/--group). Менять оригинал на
                # отставший форк смысла нет.
                #
                # Отпечаток — потому что скрипт тянется с адреса без пиннинга и
                # выполняется от root, как и остальное стороннее.
                ipregion_probe=$(mktemp /tmp/vsm-ipregion.XXXXXX.sh)
                if curl -fsSL --max-time 30 "https://ipregion.vrnt.xyz" -o "$ipregion_probe" \
                   && [ -s "$ipregion_probe" ]; then
                    upstream_fingerprint "https://ipregion.vrnt.xyz" "$ipregion_probe" || \
                        read -p "$(echo -e "${YELLOW}Enter — продолжить изменившимся скриптом...${NC}")"
                fi
                rm -f "$ipregion_probe"
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
