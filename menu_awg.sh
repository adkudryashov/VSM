#!/bin/bash
source /usr/local/bin/_config_and_utils.sh

# ----------------------------------------------------------------------
# AMNEZIAWG 3.0: УСТАНОВКА, КЛИЕНТЫ, ОБНОВЛЕНИЯ
#
# Стоит рядом со стеком telemt и панелью, не пересекаясь с ними: сервер
# слушает свой UDP-порт в host-режиме, nginx и сертификаты не трогает.
# ----------------------------------------------------------------------

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AWG_SCRIPT="$REPO_DIR/awg-stack.sh"
AWG_CONF="/etc/vsm/awg.conf"
AWG_DIR="/etc/vsm/awg"

function load_awg_conf {
    AWG_PORT=""; AWG_PROFILE=""; AWG_SRV_IMG=""; AWG_DNS_IMG=""
    AWG_TOOL_TAG=""; AWG_TOOL_SHA=""; AWG_DNS_IP=""; AWG_DNS_OK=""
    if [ -f "$AWG_CONF" ]; then
        # shellcheck disable=SC1090
        source "$AWG_CONF"
    fi
}

function awg_installed {
    [ -f "$AWG_CONF" ] && docker ps -a --filter 'name=awg-server' --format '{{.Names}}' 2>/dev/null | grep -q awg-server
}

# Состояние узла ПО ФАКТУ. «Контейнер запущен» — не критерий: он может
# крутиться в цикле рестарта, а порт при этом не слушать никто. Ровно этот
# разрыв между «служба active» и «работает» проект и ловит везде.
function awg_status_line {
    if ! awg_installed; then echo -e "${RED}НЕ УСТАНОВЛЕН${NC}"; return; fi
    local running restarts listens
    running=$(docker inspect -f '{{.State.Running}}' awg-server 2>/dev/null) || running=false
    restarts=$(docker inspect -f '{{.RestartCount}}' awg-server 2>/dev/null) || restarts=0
    listens=0
    if [ -n "$AWG_PORT" ] && ss -lun 2>/dev/null | grep -q ":${AWG_PORT}\b"; then listens=1; fi

    if [ "$running" != "true" ]; then echo -e "${RED}ОСТАНОВЛЕН${NC}"
    elif [ "$listens" -ne 1 ];    then echo -e "${RED}ПОРТ НЕ СЛУШАЕТ${NC}"
    elif [ "${restarts:-0}" -gt 0 ]; then echo -e "${YELLOW}РАБОТАЕТ, но перезапускался ${restarts} раз${NC}"
    else echo -e "${GREEN}РАБОТАЕТ${NC}"; fi
}

# Форвардинг — отдельной строкой, потому что его отсутствие ничем другим не
# видно: контейнеры подняты, порт слушает, рукопожатие проходит, а трафик
# клиентов идти некуда. Измерено на стенде после перезагрузки.
function awg_forward_line {
    local now persist
    now=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || now=0
    persist="нет"
    if grep -rqs '^net.ipv4.ip_forward *= *1' /etc/sysctl.d/ /etc/sysctl.conf 2>/dev/null; then persist="есть"; fi
    if [ "$now" = "1" ] && [ "$persist" = "есть" ]; then
        echo -e "${GREEN}включён, переживёт перезагрузку${NC}"
    elif [ "$now" = "1" ]; then
        echo -e "${YELLOW}включён, но БЕЗ постоянной записи — после ребута отвалится${NC}"
    else
        echo -e "${RED}ВЫКЛЮЧЕН — трафик клиентов никуда не идёт${NC}"
    fi
}

function awg_install {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}        🔐  УСТАНОВКА AMNEZIAWG 3.0  🔐               ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "Ставит AmneziaWG 3.0 в контейнере: обфускация с пакетами I1-I5,"
    echo -e "диапазонами заголовков и рандомизированными таймингами.\n"
    echo -e "${GREEN}Стек не затрагивается:${NC} nginx, сертификаты и порты панели"
    echo -e "и telemt остаются как есть. Занимается только один UDP-порт.\n"
    echo -e "${YELLOW}Требуется Docker — будет установлен, если его нет.${NC}\n"

    if awg_installed; then
        echo -e "${YELLOW}⚠️  AmneziaWG уже установлен. Повторная установка перевыпустит"
        echo -e "    ключ сервера, и все выданные клиентские конфиги перестанут"
        echo -e "    работать.${NC}\n"
        read -p "$(echo -e "${RED}Введите ПЕРЕУСТАНОВИТЬ для подтверждения: ${NC}")" c
        if [ "$c" != "ПЕРЕУСТАНОВИТЬ" ]; then echo -e "${BLUE}Отменено.${NC}"; sleep 1; return; fi
    fi

    local port profile
    read -p "UDP-порт (Enter — подобрать свободный): " port
    if [ -n "$port" ] && ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ Порт должен быть числом.${NC}"; read -p "Enter..."; return
    fi
    echo -e "\n${BLUE}Профили мимикрии: quic, quic0rtt, tls, noise, dtls, http3,${NC}"
    echo -e "${BLUE}sip, tls-to-quic, quic-burst, dns, random${NC}"
    read -p "Профиль [quic]: " profile

    local args=(--mode install)
    [ -n "$port" ]    && args+=(--port "$port")
    [ -n "$profile" ] && args+=(--profile "$profile")

    [ -f "$AWG_SCRIPT" ] || { echo -e "${RED}❌ Не найден $AWG_SCRIPT${NC}"; read -p "Enter..."; return; }
    bash "$AWG_SCRIPT" "${args[@]}"
    local rc=$?
    # Код возврата разбираем: установщик обрывается через die на любой
    # непройденной проверке, и молчать об этом нельзя.
    if [ "$rc" -ne 0 ]; then
        echo -e "\n${RED}❌ Установка не завершилась (код ${rc}).${NC}"
        echo -e "${YELLOW}   Стек VSM при этом не затрагивался.${NC}"
    fi
    read -p "Нажмите Enter для продолжения..."
}

function awg_clients {
    load_awg_conf
    if ! awg_installed; then
        echo -e "${RED}❌ AmneziaWG не установлен.${NC}"; read -p "Enter..."; return
    fi
    clear
    echo -e "${CYAN}--- 👥  КЛИЕНТЫ AMNEZIAWG ---${NC}\n"
    echo -e "${BLUE}Выданные пиры:${NC}"
    docker exec awg-server awg show 2>/dev/null | grep -aE '^peer|latest handshake' | sed 's/^/  /' \
        || echo -e "  ${YELLOW}(не удалось опросить сервер)${NC}"
    echo
    echo -e "1) ➕  Выдать конфиг новому клиенту"
    echo -e "X) 🔙  Назад"
    read -p "Выбор: " ch || return
    case "$ch" in
        1)
            local name endpoint
            read -p "Имя клиента (латиницей, без пробелов): " name
            if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
                echo -e "${RED}❌ Допустимы буквы, цифры, точка, дефис и подчёркивание.${NC}"
                read -p "Enter..."; return
            fi
            # Адрес подключения спрашиваем: сервер его не знает, а подставить
            # локальный IP значило бы выдать конфиг, который не работает нигде,
            # кроме самого сервера.
            read -p "Адрес сервера для клиента (домен или IP): " endpoint
            if [ -z "$endpoint" ]; then
                echo -e "${RED}❌ Без адреса конфиг работать не будет.${NC}"; read -p "Enter..."; return
            fi
            echo -e "\n${YELLOW}--- конфиг ниже, сохраните его сейчас: повторно он не выдаётся ---${NC}\n"
            docker exec -e AWG_ENDPOINT="${endpoint}:${AWG_PORT}" \
                        -e AWG_CLIENT_DNS="${AWG_DNS_IP}" \
                        awg-server awg-peer add "$name"
            echo -e "\n${YELLOW}--- конец конфига ---${NC}"
            read -p "Нажмите Enter..."
            ;;
        [Xx]) return ;;
    esac
}

# Спрашивает у реестра digest, на который СЕЙЧАС указывает тег.
#
# Не `docker manifest inspect`: у него в выводе лежат digest'ы манифестов под
# отдельные архитектуры, а зафиксирован у нас digest списка манифестов —
# сравнение в лоб давало бы «образ изменился» всегда. Проверено на стенде:
# реестр отдаёт 30f032c3…, а установлен 091c8208…, и оба верны, просто это
# разные объекты. `docker buildx imagetools` умеет нужное, но buildx в
# пакете docker.io нет. Заголовок Docker-Content-Digest даёт ровно то, что
# надо, и ничего не скачивает.
function awg_remote_digest {
    local repo="$1" tag="$2" tok d
    tok=$(curl -fsS --max-time 8 \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null \
        | grep -oP '"token":"\K[^"]+') || tok=""
    [ -n "$tok" ] || return 1
    d=$(curl -fsSI --max-time 8 -H "Authorization: Bearer $tok" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json" \
        "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" 2>/dev/null \
        | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}') || d=""
    [ -n "$d" ] || return 1
    printf '%s' "$d"
}

# Проверка обновлений. Отслеживаются ТРИ поверхности, и меняться они могут
# независимо: релиз бинарника, образ сервера и образ резолвера. Образы
# публикуются на Docker Hub отдельно от GitHub, поэтому тег там способен
# переехать на другой образ без единого коммита — сверяем по digest.
function awg_check_updates {
    load_awg_conf
    clear
    echo -e "${CYAN}--- 🔄  ПРОВЕРКА ОБНОВЛЕНИЙ ---${NC}\n"
    if [ ! -f "$AWG_CONF" ]; then
        echo -e "${RED}❌ AmneziaWG не установлен.${NC}"; read -p "Enter..."; return
    fi

    local changed=0 img name pinned remote
    for img in "$AWG_SRV_IMG:сервер" "$AWG_DNS_IMG:резолвер"; do
        name="${img##*:}"; pinned="${img%:*}"
        local repo="${pinned%@*}" digest="${pinned#*@}"
        remote=$(awg_remote_digest "$repo" "${AWG_IMG_TAG:-$AWG_TOOL_TAG}") || remote=""
        if [ -z "$remote" ]; then
            echo -e "  ${YELLOW}${name}: не удалось опросить реестр${NC}"
        elif [ "$remote" = "$digest" ]; then
            echo -e "  ${GREEN}${name}: без изменений${NC}"
        else
            echo -e "  ${RED}${name}: ОБРАЗ ИЗМЕНИЛСЯ${NC}"
            echo -e "    было:  ${digest}"
            echo -e "    стало: ${remote}"
            changed=1
        fi
    done

    local latest_tag
    latest_tag=$(curl -fsS --max-time 8 \
        https://api.github.com/repos/Vadim-Khristenko/awg-containers-and-tools/releases/latest 2>/dev/null \
        | grep -m1 -oP '"tag_name":\s*"\K[^"]+') || latest_tag=""
    if [ -z "$latest_tag" ]; then
        echo -e "  ${YELLOW}awg-tool: не удалось узнать последний релиз${NC}"
    elif [ "$latest_tag" = "$AWG_TOOL_TAG" ]; then
        echo -e "  ${GREEN}awg-tool: ${AWG_TOOL_TAG}, последний${NC}"
    else
        echo -e "  ${RED}awg-tool: установлен ${AWG_TOOL_TAG}, вышел ${latest_tag}${NC}"
        changed=1
    fi

    echo
    if [ "$changed" -eq 0 ]; then
        echo -e "${GREEN}✅ Всё соответствует зафиксированным версиям.${NC}"
    else
        echo -e "${YELLOW}Версии не фиксируются автоматически — это решение владельца.${NC}"
        echo -e "${YELLOW}Обновление означает правку пиннинга в awg-stack.sh и повторную${NC}"
        echo -e "${YELLOW}установку. Проверьте, что изменилось у автора, прежде чем идти.${NC}"
    fi
    read -p "Нажмите Enter..."
}

function awg_uninstall {
    clear
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}         🗑️   УДАЛЕНИЕ AMNEZIAWG  🗑️                  ${NC}"
    echo -e "${RED}======================================================${NC}"
    echo -e "${YELLOW}Будут удалены: контейнеры сервера и резолвера, их сеть и тома,"
    echo -e "конфигурация в ${AWG_DIR}, правило UFW и запись форвардинга.${NC}"
    echo -e "${YELLOW}Все выданные клиентские конфиги перестанут работать.${NC}"
    echo -e "${GREEN}Стек telemt, панель, nginx и сертификаты НЕ трогаются.${NC}\n"
    read -p "$(echo -e "${RED}Введите УДАЛИТЬ для подтверждения: ${NC}")" c
    if [ "$c" != "УДАЛИТЬ" ]; then echo -e "${BLUE}Отменено.${NC}"; sleep 1; return; fi
    bash "$AWG_SCRIPT" --mode uninstall
    read -p "Нажмите Enter для продолжения..."
}

function run_awg_menu {
    while true; do
        load_awg_conf
        clear
        echo -e "${CYAN}======================================================${NC}"
        echo -e "${CYAN}          🔐  AMNEZIAWG 3.0  🔐                       ${NC}"
        echo -e "${CYAN}======================================================${NC}"
        echo -e "    Узел:        [$(awg_status_line)]"
        if awg_installed; then
            echo -e "    Порт:        ${YELLOW}${AWG_PORT}/udp${NC}   профиль: ${YELLOW}${AWG_PROFILE}${NC}"
            echo -e "    Форвардинг:  [$(awg_forward_line)]"
            if [ "${AWG_DNS_OK:-1}" != "1" ]; then
                echo -e "    ${YELLOW}Резолвер не поднялся — клиенты ходят к своему DNS.${NC}"
            fi
        fi
        echo -e "${BLUE}------------------------------------------------------${NC}"
        echo -e "${YELLOW}1) 📥  Установить AmneziaWG 3.0${NC}"
        echo -e "${YELLOW}2) 👥  Клиенты (список и выдача конфигов)${NC}"
        echo -e "${YELLOW}3) 🔄  Проверить обновления${NC}"
        echo -e "${YELLOW}4) 📜  Журнал сервера${NC}"
        echo -e "${RED}5) 🗑️   Удалить AmneziaWG${NC}"
        echo -e "${RED}X) 🔙  Назад в главное меню${NC}"
        echo -e "${BLUE}------------------------------------------------------${NC}"

        # "|| return" обязателен: при закрытом stdin read возвращается мгновенно
        # и пустым, и цикл меню занимает ядро целиком — поймано на прогоне
        # меню через пайп.
        read -p "Ваш выбор [1-5, X]: " choice || return
        echo ""
        case $choice in
            1) awg_install ;;
            2) awg_clients ;;
            3) awg_check_updates ;;
            4) docker logs --tail 60 awg-server 2>&1 | sed 's/^/  /'; read -p "Enter..." ;;
            5) awg_uninstall ;;
            [Xx]) return ;;
            *) echo -e "${RED}❌ Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

run_awg_menu
