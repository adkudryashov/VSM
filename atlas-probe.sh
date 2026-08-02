#!/bin/bash

# ============================================================================
# ПРОБА RIPE ATLAS — размещение программной пробы ради кредитов
#
# Зачем: радар ТСПУ в censorcheck.sh — единственный уровень проверки, который
# видит фильтрацию у ДОМАШНЕГО абонента, — стоит 200 кредитов за замер. Без
# кредитов он молчит, и отчёт остаётся неполным. Подключённая проба приносит
# 15 кредитов в минуту (~21 600 в сутки), то есть примерно сотню прогонов
# радара в день.
#
# ВАЖНО про размещение: кредиты начисляются на АККАУНТ, а не на машину. Пробу
# можно поставить где угодно — домашний компьютер, отдельный VPS — и она будет
# финансировать замеры для всех ваших серверов. Ставить её именно на прокси
# необязательно, и по умолчанию это не лучший выбор (см. предупреждения ниже).
#
# Чем это отличается от прочих сторонних установок в VSM: здесь НЕ выполняется
# скачанный скрипт. Ставятся подписанные пакеты, и подпись проверяется по
# отпечатку, зашитому в этот файл, — цепочка та же, что у apt.
#
# Режимы:
#   --install   установка (интерактивная, со всеми предупреждениями)
#   --status    состояние пробы и баланс кредитов
#   --key       показать ключ пробы для регистрации
#   --remove    удаление
# ============================================================================

CC_CONF="/etc/vsm/censorcheck.conf"

# Официальных пакетов под Ubuntu нет вовсе: в репозитории RIPE только Debian
# (bookworm/bullseye/trixie) и RHEL. На Ubuntu ставим пакеты bookworm через
# dpkg, НЕ подключая репозиторий к apt: иначе apt начнёт тянуть зависимости из
# Debian и разломает систему. Зависимости пакета при этом удовлетворимы
# штатными пакетами Ubuntu (libssl3 предоставляется libssl3t64).
ATLAS_BASE="https://ftp.ripe.net/ripe/atlas/software-probe/debian"
ATLAS_SUITE="bookworm"
ATLAS_ARCH="amd64"

# Ключ, которым RIPE подписывает репозиторий, зашит прямо сюда вместе с
# отпечатком. Именно он — единственный якорь доверия: качать ключ оттуда же,
# откуда пакеты, бессмысленно (подменённое зеркало отдало бы свой ключ, и
# подпись сошлась бы). Заодно это избавляет от распаковки чужого .deb от root
# ради одного файла.
#
# uid atlas+probe-prod-20240924@ripe.net, RSA 4096.
ATLAS_GPG_FPR="3AA1535BDE7A832211A47D46D97345B4F6FCF4B8"

read -r -d '' ATLAS_GPG_KEY <<'ATLAS_KEY_EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGbyrAwBEADIT+rYVlzTSWYsC/oNsIQI+B+iX9o9zfphcjHGsRLdnzBx0ZjM
8schxbUP5xu3DzA6pBftasQPEXqlDA6HFxaX3L7wCPqRDRKcy7K5ChDdR7nBWS6I
sOp6eNeox2FJ8BbEAl3agT+q3NXzFUZfYfaqnNLqlNuJ2/aJjOrbo9X9Jl4u8eu5
KCDqGSaY9DlyYpBOue9HGOaLgbjBTDOWcicXek+z1yU59aULlsx8BlAuxfo9l/NR
0m05bTnoUcSwzhYQykhlGQweEQHYlGyEANwGwskuuWD0KmvlZdfICWAMiHKryW7K
lI3/0YA0LaA3Z0WxGyNTe2Fr1J/ePJ3biMt43U8mf3P0KYbVS+dMJGK7AFVgLVIJ
luZq6nTdW8+eHNf6xGi79XhBLdsCoNp2cV01D30euxDZdZFMSR1GnLIcZ/dWSDWN
wnIwRVWrbAFlq9ddWsdapwZZAEE1r0TRgaOAMAHHjiZObwLnIEb/qL157rmdGPS6
WW3WFyWcfQIUuqRcIennBpfMyU0rh2yHbkfFnL9oWDNcLb6jYPMnDk7SgKw8Cf7F
YkXdYQtE+iGdX5JiYFrIJYMJ1q0DdMMHTSCGDAsXaWfREJ36BRrU8fD28rA3KBx4
EuEbGFD4Jrfkar7Id+6jiN23LQOHRtnV+jLVykaw0xg53up96wRwVS3eRwARAQAB
tCJhdGxhcytwcm9iZS1wcm9kLTIwMjQwOTI0QHJpcGUubmV0iQJOBBMBCgA4FiEE
OqFTW956gyIRpH1G2XNFtPb89LgFAmbyrAwCGwMFCwkIBwIGFQoJCAsCBBYCAwEC
HgECF4AACgkQ2XNFtPb89LjX4hAAgYYp2VDiGsnlxUYs3M2A5BhVwxq1FFvEKV3I
4yXH1tzoeHgMOUb2lJxoRxUGYDXFl0PhFucQrcn9p6qEZszy7r8k/4XWpLP9RMJc
w30YdSQIt89OadnFU+Zm93Eg1waH3FR7gD5k1b994S9Am7ny3u8UdpEFWrcSRb5J
1EZEyUo+M+aRTln1KuVVJAuCcdVgZ4JsygTVWeA++9qAdUgDouDTTiaqS4JBhaXj
jI0ckMEZg82fbgfeM1PN2qaj/TiGa+i3yJDvGUsPRUE+WcSOv+kJF4YupGHLzDBF
QSyK+G0lvMSyZzfYaOG84n/kEixUBEnK2yWdb/2eUPS9pqKC4er1FCctHuIX6/L8
ryPagPDX1rtQ/I4GqC/TYWSFxBRSumVo7H37zfWNJpsCe3YENpa+eAKXBkFrzQLn
BWCiNUZ0Mn7hTGablur0sYJdEPdrIQAucLJZG+0iP34fViWDPwCNIUPGtHcouesw
G5cC5aLYziumbdeF9GtjyPXuXxXt28e7mUBh8yVL1VcQYyfS4ueKeD2lgVF9T++p
DSKW9gIwRJ54vbr3jdRnwblwdG7KUF9qRwGXKvRkxUABAs8KOj34Ldpn2HMcY4uJ
VCi1RGFnBdkWcL+jjGBb+5feM9jfQfLgBPmOI8fuqS3NYrERA489PawLx5/Fm8FA
ArL98yM=
=GOfn
-----END PGP PUBLIC KEY BLOCK-----
ATLAS_KEY_EOF

PROBE_KEY_FILE="/etc/ripe-atlas/probe_key.pub"
PROBE_SERVICE="ripe-atlas"
PROBE_APPLY_URL="https://atlas.ripe.net/apply/swprobe/"

if [ -f /usr/local/bin/_config_and_utils.sh ]; then
    # shellcheck disable=SC1091
    source /usr/local/bin/_config_and_utils.sh
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
fi

# ---------------------------------------------------------------------------
# ОБЩЕЕ
# ---------------------------------------------------------------------------

# Текст, пришедший от RIPE, перед выводом обезвреживается: echo -e развернул бы
# \e[ в настоящие управляющие последовательности терминала.
sanitize() { printf '%s' "$1" | tr -d '\033\r' | sed 's/\\/\\\\/g'; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ Нужны права root.${NC}"
        return 1
    fi
}

# Установлена ли проба.
#
# Именно "install ok installed", а не код возврата dpkg -s: после обычного
# `dpkg -r` пакет остаётся в базе со статусом "deinstall ok config-files", и
# `dpkg -s` на нём возвращает НОЛЬ. С проверкой по коду возврата удаление и
# повторная установка ломались бы: скрипт говорил бы «уже установлена» на
# пустом месте.
probe_is_installed() {
    dpkg-query -W -f='${Status}' ripe-atlas-common 2>/dev/null \
        | grep -q '^install ok installed' && return 0
    [ -f "$PROBE_KEY_FILE" ]
}

# Зарегистрирована ли проба. Признак — появившийся идентификатор: до одобрения
# RIPE его нет, и служба крутится вхолостую.
probe_id() {
    local f
    for f in /var/atlas-probe/status/p_id /var/atlas-probe/etc/probe_id; do
        [ -s "$f" ] && { tr -dc '0-9' < "$f" | head -c 12; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# ЦЕПОЧКА ДОВЕРИЯ
# ---------------------------------------------------------------------------
# Повторяем то, что делает apt, но без подключения репозитория:
#   InRelease (подпись проверена зашитым отпечатком)
#     └── SHA256 индекса Packages
#           └── SHA256 каждого .deb
# Обрыв на любом звене — отказ, а не установка «как-нибудь».

# Извлечение SHA256 файла из подписанного InRelease.
inrelease_hash() {
    local inrel="$1" want="$2"
    gpg --quiet --decrypt "$inrel" 2>/dev/null | awk -v w="$want" '
        /^SHA256:/ { s = 1; next }
        # Секция SHA256 закончилась, как только строка перестала быть отступом
        s && !/^ / { exit }
        s && $3 == w { print $1; exit }
    '
}

# Путь и SHA256 последней версии пакета из индекса Packages.
#
# «Последняя» определяется через dpkg --compare-versions, а не сортировкой
# строк: у сортировки 5100 оказалось бы новее 590, и с ростом номеров это
# однажды выстрелило бы молча.
package_latest() {
    local packages="$1" name="$2"
    awk -v n="$name" '
        $1 == "Package:" { pkg = $2; ver = fn = sh = "" }
        $1 == "Version:"  { ver = $2 }
        $1 == "Filename:" { fn  = $2 }
        $1 == "SHA256:"   { sh  = $2 }
        /^$/ { if (pkg == n && ver && fn && sh) print ver, fn, sh; pkg = "" }
        END  { if (pkg == n && ver && fn && sh) print ver, fn, sh }
    ' "$packages" | {
        local best_v="" best_line="" v rest
        while read -r v rest; do
            if [ -z "$best_v" ] || dpkg --compare-versions "$v" gt "$best_v"; then
                best_v="$v"; best_line="$v $rest"
            fi
        done
        [ -n "$best_line" ] && echo "$best_line"
    }
}

verify_sha256() {
    local file="$1" want="$2" got
    got=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
    [ -n "$got" ] && [ "$got" = "$want" ]
}

# Импорт ЗАШИТОГО ключа RIPE во временную связку.
#
# Ключ нигде не скачивается: качать его с того же зеркала, откуда пакеты,
# значило бы проверять подпись ключом злоумышленника. Сверка отпечатка после
# импорта — защита не от зеркала, а от опечатки в самом этом файле: если
# зашитый ключ и зашитый отпечаток разошлись, установка обязана встать, а не
# молча доверять непонятно чему.
import_ripe_key() {
    local workdir="$1"
    local keyfile="$workdir/ripe.asc"

    printf '%s\n' "$ATLAS_GPG_KEY" > "$keyfile" || return 1

    export GNUPGHOME="$workdir/gnupg"
    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME" || return 1
    gpg --quiet --import "$keyfile" 2>/dev/null || return 1

    local fpr
    fpr=$(gpg --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    if [ "$fpr" != "$ATLAS_GPG_FPR" ]; then
        echo -e "${RED}❌ Зашитый ключ не соответствует зашитому отпечатку.${NC}" >&2
        echo -e "${YELLOW}   ожидался: $ATLAS_GPG_FPR${NC}" >&2
        echo -e "${YELLOW}   получен:  ${fpr:-ключ не импортировался}${NC}" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# УСТАНОВКА
# ---------------------------------------------------------------------------

install_warning_screen() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}   📡  ПРОБА RIPE ATLAS — КРЕДИТЫ ДЛЯ РАДАРА  📡      ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "Радар ТСПУ стоит 200 кредитов за замер. Подключённая проба даёт"
    echo -e "15 кредитов в минуту — около 21 600 в сутки, то есть примерно"
    echo -e "сотню прогонов радара в день.\n"

    echo -e "${GREEN}Кредиты начисляются на АККАУНТ, а не на машину.${NC}"
    echo -e "${YELLOW}Пробу можно поставить на домашний компьютер или отдельный VPS —"
    echo -e "она будет кормить радар для всех ваших серверов. Ставить её"
    echo -e "именно на этот сервер необязательно.${NC}\n"

    echo -e "${RED}⚠️  ЧТО СТАНЕТ ПУБЛИЧНЫМ${NC}"
    echo -e "${YELLOW}   Точный адрес IPv4 этого сервера попадёт в открытый каталог"
    echo -e "   RIPE Atlas вместе с ASN, префиксом, страной и координатами,"
    echo -e "   огрублёнными до 1 км. Каталог отдаётся по API без ключа и"
    echo -e "   фильтруется по стране и ASN — то есть ваш адрес можно получить"
    echo -e "   перебором всего списка, не зная заранее ни домена, ни чего-либо"
    echo -e "   ещё. Программные пробы бывают ТОЛЬКО публичными.${NC}\n"

    echo -e "${GREEN}⚠️  ЧЕГО НЕ ПРОИЗОЙДЁТ${NC}"
    echo -e "${YELLOW}   Новых открытых портов не появится: управляющий telnetd слушает"
    echo -e "   только 127.0.0.1, а связь с RIPE идёт ИСХОДЯЩИМ SSH с обратным"
    echo -e "   туннелем. Снаружи сервер выглядит ровно так же, как сейчас, —"
    echo -e "   маскировка не страдает.${NC}\n"

    echo -e "${YELLOW}   Ещё стоит знать:"
    echo -e "   • проба выполняет замеры по заказу чужих людей к произвольным"
    echo -e "     целям — возможны жалобы хостера на «сканирование»;"
    echo -e "   • история подключений и результаты встроенных замеров публичны;"
    echo -e "   • отзыв пробы обратим НЕ полностью: страница остаётся в каталоге"
    echo -e "     со статусом «abandoned», прошлые данные не удаляются.${NC}\n"

    # Про способ установки пользователь тоже должен узнать до согласия, а не из
    # комментария в начале файла, которого он не видит.
    echo -e "${YELLOW}   Как именно ставится:"
    echo -e "   • подписанные пакеты RIPE, подпись проверяется зашитым ключом;"
    echo -e "   • устанавливает их dpkg, а он выполняет служебные скрипты пакета"
    echo -e "     от root — как и любая установка пакета в системе;"
    if [ -f /etc/os-release ] && grep -qi '^ID=ubuntu' /etc/os-release; then
        echo -e "   • у RIPE нет пакетов под Ubuntu, поэтому ставятся пакеты Debian"
        echo -e "     ${ATLAS_SUITE}. Репозиторий в apt НЕ добавляется, зависимости"
        echo -e "     берутся штатные. Связка рабочая, но не поддерживается RIPE;"
    fi
    echo -e "   • RIPE не публикует срок годности своего индекса, поэтому"
    echo -e "     подлинность проверяется, а свежесть — нет.${NC}\n"
}

do_install() {
    need_root || return 1

    if probe_is_installed; then
        echo -e "${YELLOW}Проба уже установлена. Состояние — пункт «статус».${NC}"
        return 0
    fi

    install_warning_screen

    echo -e "${BLUE}------------------------------------------------------${NC}"
    echo -e "${RED}Это осознанная публикация адреса сервера.${NC}"
    read -r -p "$(echo -e "${CYAN}Введите ${NC}СОГЛАСЕН${CYAN} для установки: ${NC}")" confirm
    if [ "$confirm" != "СОГЛАСЕН" ]; then
        echo -e "${BLUE}Отменено.${NC}"
        return 0
    fi

    # Имя пробы здесь НЕ спрашиваем: config.txt его не содержит. Проверено по
    # самому пакету — config_lookup читает ровно три ключа (RXTXRPT,
    # TELNETD_PORT, HTTP_POST_PORT), а слова DESCRIPTION в нём нет вовсе.
    # Имя задаётся в форме регистрации, туда предупреждение и перенесено.
    local workdir
    workdir=$(mktemp -d /tmp/vsm-atlas.XXXXXX) || return 1
    # RETURN закрывает обычные выходы, включая ранние return; INT и TERM — обрыв
    # по Ctrl+C во время долгой загрузки, иначе временный каталог со связкой
    # ключей и пакетами оставался бы в /tmp до перезагрузки.
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN INT TERM

    echo -e "\n${CYAN}>>> Проверяю зависимости...${NC}"
    # ensure_packages сверяется по ИМЕНИ КОМАНДЫ, поэтому годится только для
    # пакетов, приносящих команду. Библиотеки проверяем через dpkg отдельно.
    # Запасной путь нужен, если скрипт запущен из репозитория, а не из
    # /usr/local/bin: тогда _config_and_utils.sh не подхватился.
    if declare -F ensure_packages >/dev/null; then
        if ! ensure_packages net-tools:netstat psmisc:killall openssh-client:ssh \
                             libcap2-bin:setcap gnupg:gpg; then
            echo -e "${RED}❌ Не удалось поставить зависимости.${NC}"
            return 1
        fi
    else
        local miss=() c
        for c in netstat killall ssh setcap gpg; do
            command -v "$c" &>/dev/null || miss+=("$c")
        done
        if [ ${#miss[@]} -gt 0 ]; then
            echo -e "${RED}❌ Не хватает команд: ${miss[*]}${NC}"
            echo -e "${YELLOW}   Поставьте: apt install net-tools psmisc openssh-client libcap2-bin gnupg${NC}"
            return 1
        fi
    fi
    local libssl_ok=0
    local p
    for p in libssl3 libssl3t64; do
        dpkg -s "$p" &>/dev/null && libssl_ok=1
    done
    if [ "$libssl_ok" -eq 0 ]; then
        echo -e "${RED}❌ Не найден libssl3 (или libssl3t64) — пакет пробы без него не встанет.${NC}"
        return 1
    fi

    echo -e "${CYAN}>>> Скачиваю и проверяю подпись репозитория...${NC}"
    local inrel="$workdir/InRelease" packages="$workdir/Packages"
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 "$ATLAS_BASE/dists/$ATLAS_SUITE/InRelease" -o "$inrel"; then
        echo -e "${RED}❌ Не удалось скачать InRelease. Проверьте доступ к ftp.ripe.net.${NC}"
        return 1
    fi

    # Ключ лежит внутри пакета, а путь к пакету — в индексе. Поэтому индекс
    # сначала качается «начерно», без доверия: по нему находится только ключ, а
    # сам индекс проверяется ниже суммой из УЖЕ проверенного InRelease.
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 \
            "$ATLAS_BASE/dists/$ATLAS_SUITE/main/binary-$ATLAS_ARCH/Packages" -o "$packages"; then
        echo -e "${RED}❌ Не удалось скачать индекс пакетов.${NC}"
        return 1
    fi
    if ! import_ripe_key "$workdir" "$packages"; then
        echo -e "${RED}❌ Не удалось получить и подтвердить ключ RIPE. Установка прервана.${NC}"
        return 1
    fi

    # Условие сформулировано «продолжаем, только если совпадений РОВНО столько,
    # сколько ждём». Обратная запись ([ "$sig" -eq 0 ] && стоп) при нечисловом
    # $sig давала бы ошибку test, ненулевой код — и ветка отказа не сработала
    # бы, то есть сбой открывал бы дорогу установке.
    local sig
    sig=$(gpg --status-fd 1 --verify "$inrel" 2>/dev/null \
          | grep -c "^\[GNUPG:\] VALIDSIG $ATLAS_GPG_FPR")
    if ! [[ "$sig" =~ ^[0-9]+$ ]] || [ "$sig" -lt 1 ]; then
        echo -e "${RED}❌ Подпись InRelease не подтверждена ожидаемым ключом. Установка прервана.${NC}"
        return 1
    fi
    echo -e "${GREEN}    подпись репозитория верна (${ATLAS_GPG_FPR:0:16}…)${NC}"

    # Индекс проверяем СУММОЙ ИЗ ПОДПИСАННОГО InRelease — тот, что скачали для
    # добычи ключа, до этой минуты доверия не заслуживал.
    local want_pkg_hash
    want_pkg_hash=$(inrelease_hash "$inrel" "main/binary-$ATLAS_ARCH/Packages")
    if [ -z "$want_pkg_hash" ]; then
        echo -e "${RED}❌ В InRelease нет суммы индекса пакетов.${NC}"
        return 1
    fi
    if ! verify_sha256 "$packages" "$want_pkg_hash"; then
        echo -e "${RED}❌ Индекс пакетов не совпал с подписанной суммой. Установка прервана.${NC}"
        return 1
    fi
    echo -e "${GREEN}    индекс пакетов совпал с подписанной суммой${NC}"

    echo -e "${CYAN}>>> Скачиваю пакеты пробы...${NC}"
    local debs=() pkg line ver fn sh out
    for pkg in ripe-atlas-common ripe-atlas-probe; do
        line=$(package_latest "$packages" "$pkg")
        if [ -z "$line" ]; then
            echo -e "${RED}❌ В индексе нет пакета $pkg.${NC}"
            return 1
        fi
        read -r ver fn sh <<< "$line"
        out="$workdir/$(basename "$fn")"
        if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-time 120 "$ATLAS_BASE/$fn" -o "$out"; then
            echo -e "${RED}❌ Не удалось скачать $pkg.${NC}"
            return 1
        fi
        if ! verify_sha256 "$out" "$sh"; then
            echo -e "${RED}❌ Контрольная сумма $pkg не совпала. Установка прервана.${NC}"
            return 1
        fi
        echo -e "${GREEN}    $pkg $ver — сумма совпала${NC}"
        debs+=("$out")
    done

    echo -e "${CYAN}>>> Устанавливаю...${NC}"
    if ! dpkg -i "${debs[@]}"; then
        echo -e "${RED}❌ dpkg не смог поставить пакеты.${NC}"
        echo -e "${YELLOW}   Разобрать зависимости: apt-get -f install${NC}"
        return 1
    fi

    if systemctl enable --now "$PROBE_SERVICE" &>/dev/null; then
        echo -e "\n${GREEN}✅ Пакеты установлены, служба запущена.${NC}"
    else
        # Раньше здесь безусловно печаталось «установлено»: пакеты на месте, а
        # служба лежит — и пользователь узнавал об этом только из статуса.
        echo -e "\n${YELLOW}⚠️  Пакеты установлены, но служба не поднялась.${NC}"
        echo -e "${YELLOW}   Смотрите: journalctl -u $PROBE_SERVICE -n 30${NC}"
    fi
    show_registration
}

# ---------------------------------------------------------------------------
# РЕГИСТРАЦИЯ
# ---------------------------------------------------------------------------
# Автоматизировать нечего: RIPE принимает ключ только веб-формой, и одобряет
# его человек. Поэтому просто показываем ключ и ссылку.
show_registration() {
    echo -e "\n${CYAN}======================================================${NC}"
    echo -e "${CYAN}  ОСТАЛСЯ ОДИН ШАГ — РЕГИСТРАЦИЯ (вручную)            ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    if [ ! -s "$PROBE_KEY_FILE" ]; then
        echo -e "${YELLOW}Ключ пробы ещё не создан. Он появляется через несколько секунд"
        echo -e "после первого запуска службы. Загляните сюда снова чуть позже:"
        echo -e "${CYAN}   $PROBE_KEY_FILE${NC}"
        return 0
    fi
    echo -e "${YELLOW}1. Скопируйте этот ключ:${NC}\n"
    # printf, а не echo -e: содержимое файла выводим как есть, без разворота
    # escape-последовательностей — та же политика, что и для текста от RIPE.
    printf '%s\n\n' "$(cat "$PROBE_KEY_FILE")"
    echo -e "${YELLOW}2. Отправьте его формой: ${CYAN}$PROBE_APPLY_URL${NC}"
    echo -e "${YELLOW}   Там же задаётся ИМЯ пробы. Оно попадёт в открытый каталог —"
    echo -e "   не называйте её так, чтобы по имени читалось назначение сервера.${NC}"
    echo -e "${YELLOW}3. Дождитесь одобрения. Сколько оно идёт, RIPE не обещает."
    echo -e "   До одобрения проба работает вхолостую и кредитов не приносит.${NC}"
}

# ---------------------------------------------------------------------------
# СОСТОЯНИЕ
# ---------------------------------------------------------------------------

# Баланс кредитов. Ключ тот же, что у радара. Молча пусто, если ключа нет или
# сеть недоступна: баланс — справка, а не повод для отказа.
credits_balance() {
    local key=""
    [ -f "$CC_CONF" ] && key=$(grep -m1 '^RIPE_API_KEY=' "$CC_CONF" 2>/dev/null | cut -d= -f2- | tr -d "\"'")
    [ -z "$key" ] && return 1
    curl -fsS --max-time 10 -H "Authorization: Key $key" \
        "https://atlas.ripe.net/api/v2/credits/" 2>/dev/null \
        | grep -oE '"current_balance"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$'
}

# Одна строка для шапки меню. Сеть НЕ трогаем: шапка перерисовывается при
# каждом возврате в меню, и запрос к RIPE подвешивал бы её на таймаут всякий
# раз, когда сети нет.
status_line() {
    local id
    if ! probe_is_installed; then
        echo -e "${RED}НЕ УСТАНОВЛЕНА${NC}"
        return
    fi
    if ! systemctl is-active --quiet "$PROBE_SERVICE" 2>/dev/null; then
        echo -e "${YELLOW}УСТАНОВЛЕНА, СЛУЖБА НЕ РАБОТАЕТ${NC}"
        return
    fi
    if id=$(probe_id); then
        echo -e "${GREEN}РАБОТАЕТ (ID $id)${NC}"
    else
        echo -e "${YELLOW}ЖДЁТ РЕГИСТРАЦИИ${NC}"
    fi
}

do_status() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}   📡  СОСТОЯНИЕ ПРОБЫ RIPE ATLAS  📡                 ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "Проба:      [$(status_line)]"

    if ! probe_is_installed; then
        echo -e "\n${YELLOW}Радар ТСПУ работает на кредитах, а кредиты даёт проба."
        echo -e "Поставить её можно пунктом «Разместить пробу».${NC}"
        return 0
    fi

    local id bal
    id=$(probe_id) && echo -e "Страница:   ${CYAN}https://atlas.ripe.net/probes/$id/${NC}"
    echo -e "Служба:     $(systemctl is-active "$PROBE_SERVICE" 2>&1)"

    echo -e "\n${CYAN}Запрашиваю баланс кредитов...${NC}"
    if bal=$(credits_balance) && [ -n "$bal" ]; then
        echo -e "Кредиты:    ${GREEN}${bal}${NC}"
        if [ "$bal" -lt 200 ] 2>/dev/null; then
            echo -e "${YELLOW}            Замер радара стоит 200 — пока не хватает.${NC}"
        else
            echo -e "${GREEN}            Хватает на $(( bal / 200 )) прогонов радара.${NC}"
        fi
    else
        echo -e "Кредиты:    ${YELLOW}не удалось узнать (нет ключа или сети)${NC}"
    fi

    # Главная проверка всей затеи: проба не должна была открыть ни одного
    # порта наружу. Показываем это прямо, а не просим верить на слово.
    echo -e "\n${CYAN}Порты, открытые пробой наружу:${NC}"
    local ext
    ext=$(ss -ltnp 2>/dev/null | grep -i "ripe-atlas\|telnetd" | grep -vE '127\.0\.0\.1|\[::1\]')
    if [ -z "$ext" ]; then
        echo -e "${GREEN}    нет — как и должно быть${NC}"
    else
        echo -e "${RED}    НАЙДЕНЫ, это не ожидалось:${NC}"
        echo "$ext"
    fi
}

# ---------------------------------------------------------------------------
# УДАЛЕНИЕ
# ---------------------------------------------------------------------------

do_remove() {
    need_root || return 1
    if ! probe_is_installed; then
        echo -e "${YELLOW}Проба не установлена.${NC}"
        return 0
    fi

    local id; id=$(probe_id)
    echo -e "${RED}Удаление пробы RIPE Atlas.${NC}"
    echo -e "${YELLOW}Пакеты и данные пробы будут удалены с сервера.${NC}\n"
    echo -e "${RED}⚠️  Удаление здесь НЕ убирает пробу из каталога RIPE.${NC}"
    echo -e "${YELLOW}   Её нужно отозвать самому, иначе она останется висеть:"
    if [ -n "$id" ]; then
        echo -e "   ${CYAN}https://atlas.ripe.net/probes/$id/${NC}"
    else
        echo -e "   ${CYAN}https://atlas.ripe.net/probes/${NC}"
    fi
    echo -e "${YELLOW}   Прошлые данные и страница пробы сохранятся в любом случае.${NC}\n"

    read -r -p "$(echo -e "${CYAN}Введите ${NC}УДАЛИТЬ${CYAN} для подтверждения: ${NC}")" confirm
    if [ "$confirm" != "УДАЛИТЬ" ]; then
        echo -e "${BLUE}Отменено.${NC}"
        return 0
    fi

    systemctl disable --now "$PROBE_SERVICE" &>/dev/null
    # Именно purge, а не remove: после remove запись остаётся в базе dpkg, и
    # повторная установка через этот же пункт считала бы пробу уже стоящей.
    dpkg -P ripe-atlas-probe ripe-atlas-common &>/dev/null \
        || echo -e "${YELLOW}   dpkg сообщил об ошибке, чищу файлы вручную.${NC}"
    rm -rf /etc/ripe-atlas /var/atlas-probe
    systemctl daemon-reload &>/dev/null

    echo -e "\n${GREEN}✅ Проба удалена с сервера.${NC}"
    [ -n "$id" ] && echo -e "${YELLOW}   Не забудьте отозвать её на atlas.ripe.net (ID $id).${NC}"
}

# ---------------------------------------------------------------------------
case "${1:---status}" in
    --install) do_install ;;
    --status)  do_status ;;
    --key)     show_registration ;;
    --remove)  do_remove ;;
    --line)    status_line ;;   # для шапки меню
    *)
        echo "Использование: $0 [--install | --status | --key | --remove]"
        exit 2
        ;;
esac
