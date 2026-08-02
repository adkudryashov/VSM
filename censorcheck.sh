#!/bin/bash

# ============================================================================
# CENSORCHECK — проверка доступности стека VSM из России
#
# Заменяет прежний вызов стороннего скрипта с сайта автора. Причины замены:
#   • тот скрипт скачивался и выполнялся от root с чужого домена — доверие
#     к коду проверялось только доступностью сайта;
#   • радар ТСПУ в нём работает на ключе RIPE Atlas автора, при его же
#     просьбе не использовать ключ в сторонних проектах: чужая квота, и
#     отвалиться могло в любой момент не по нашей воле;
#   • отказ любой внешней площадки выглядел как «проверка прошла».
#
# Три уровня наблюдения, каждый деградирует честно и по отдельности:
#   1. Локально      — здоровье собственного стека (DNS, слушатели, TLS).
#   2. check-host.net— видимость из РФ с датацентровых узлов, без ключа.
#   3. RIPE Atlas    — радар ТСПУ с проб в домашних и мобильных сетях РФ.
#
# Уровни отвечают на РАЗНЫЕ вопросы и не заменяют друг друга. ТСПУ стоит у
# операторов связи: датацентровый узел может видеть сервер прекрасно ровно
# тогда, когда домашний абонент не может подключиться вовсе.
#
# Коды возврата (для cron и ботов):
#   0 — признаков блокировки не найдено
#   1 — блокировка части точек наблюдения
#   2 — сервер не виден из РФ
#   3 — проверка не выполнена (нет данных)
# ============================================================================

CC_CONF="/etc/vsm/censorcheck.conf"
STACK_CONF="/etc/vsm/telemt.conf"
BOTS_ENV="/root/VSM/bots/.env"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROBE="$SCRIPT_DIR/_censorcheck_probe.py"

if [ -f /usr/local/bin/_config_and_utils.sh ]; then
    # shellcheck disable=SC1091
    source /usr/local/bin/_config_and_utils.sh
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
fi

# Локаль задаётся явно: скрипт рассчитан и на cron, где окружение урезано до
# LANG=C. В такой локали ${#s} снова считает БАЙТЫ, и всё выравнивание колонок
# разъезжается ровно там, где отчёт читают не глядя — в письме или в боте.
if locale -a 2>/dev/null | grep -qiE '^(C\.utf-?8|en_US\.utf-?8)$'; then
    export LC_ALL=$(locale -a 2>/dev/null | grep -iE '^(C\.utf-?8|en_US\.utf-?8)$' | head -1)
fi

REPORT=""          # копия вывода для Telegram, уже без ANSI
WORST=0            # худший встреченный код возврата

# Текст, пришедший от сторонней площадки, перед выводом обезвреживается:
# say() печатает через echo -e, а тот разворачивает \e[ и прочие escape-и в
# настоящие управляющие последовательности терминала. Ответ check-host или
# RIPE Atlas — не наш текст, и рисовать им что попало в терминале администратора
# он не должен.
sanitize() { printf '%s' "$1" | tr -d '\033\r' | sed 's/\\/\\\\/g'; }

say() { echo -e "$1"; REPORT+="$(echo -e "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')"$'\n'; }
worst() { [ "$1" -gt "$WORST" ] && WORST="$1"; return 0; }

# Дополнение строки до нужной ШИРИНЫ В СИМВОЛАХ.
#
# printf '%-22s' здесь не годится: он считает байты, а кириллица в UTF-8 берёт
# по два байта на символ — русские подписи оказывались короче на свою длину, и
# колонки разъезжались тем сильнее, чем больше в подписи кириллицы.
# ${#s} считает именно символы, поэтому добиваем пробелами сами.
pad() {
    local s="$1" w="$2" n
    n=$(( w - ${#s} )); (( n < 0 )) && n=0
    printf '%s%*s' "$s" "$n" ''
}

# Заголовок раздела фиксированной ширины: подставляемый домен имеет
# произвольную длину, и дописывание хвоста фиксированной строкой давало
# разделители разной длины в одном экране.
section() {
    local title="$1" line
    local w=$(( 54 - ${#title} - 5 ))
    (( w < 3 )) && w=3    # printf с отрицательной шириной выравнивает влево и
                          # выдаёт хвост ДЛИННЕЕ, а не короче
    line=$(printf '%*s' "$w" '' | tr ' ' '-')
    say "\n${BLUE}--- ${title} ${line}${NC}"
}

# ---------------------------------------------------------------------------
# ПОДГОТОВКА
# ---------------------------------------------------------------------------
load_conf() {
    RIPE_API_KEY=""; ATLAS_PROBES=10
    [ -f "$CC_CONF" ] && . "$CC_CONF"
    DOMAIN_PANEL=""; DOMAIN_REALITY=""; TELEMT_PORT=""; PANEL_PORT=""
    [ -f "$STACK_CONF" ] && . "$STACK_CONF"
}

# Собственный внешний адрес. Три источника подряд: если сервер уже частично
# отрезан, первый может не ответить, а без адреса не с чем сверять DNS.
detect_own_ip() {
    local ip src
    for src in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip=$(curl -4 -fsS --max-time 8 "$src" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$ip"; return 0; fi
    done
    # Запасной вариант без интернета — адрес маршрута по умолчанию.
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1
}

# ---------------------------------------------------------------------------
# УРОВЕНЬ 1 — ЛОКАЛЬНО
# ---------------------------------------------------------------------------
# Здесь проверяется ТОЛЬКО здоровье своего стека. Зондировать отсюда DPI
# бессмысленно: трафик сервера к самому себе не проходит через фильтры
# российских операторов, и «успех» такой проверки ничего не доказывал бы.
# Второй аргумент — эталонный адрес. Он есть только для СВОИХ доменов, где мы
# точно знаем правильный ответ. Для произвольного домена эталона нет, и
# сверять его с адресом нашего сервера было бы бессмысленно: любой чужой домен
# всегда «не совпадал» бы. Без эталона резолверы сверяются между собой —
# расхождение между ними и есть признак подмены.
check_dns() {
    local domain="$1" expected="$2" resolver answer label
    local -a labels=() answers=()
    section "DNS: $domain"

    for resolver in "" "8.8.8.8" "1.1.1.1" "77.88.8.8"; do
        label="${resolver:-системный}"
        if [ -z "$resolver" ]; then
            answer=$(dig +short +time=3 +tries=1 A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
        else
            answer=$(dig +short +time=3 +tries=1 A "$domain" "@$resolver" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
        fi
        labels+=("$label"); answers+=("$answer")
    done

    # Без эталона за него принимается самый частый ответ. Одиночное расхождение
    # на фоне согласного большинства — это и есть подозрительный резолвер.
    local reference="$expected"
    if [ -z "$reference" ]; then
        reference=$(printf '%s\n' "${answers[@]}" | grep -v '^$' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    fi

    local i mismatch=0 dead=0 bogus=0
    for i in "${!labels[@]}"; do
        if [ -z "${answers[$i]}" ]; then
            say "  ${RED}✗${NC} $(pad "${labels[$i]}" 12) не отвечает"
            dead=1
        elif is_bogus_ip "${answers[$i]}"; then
            # Заглушка вместо адреса — это не «другой узел CDN», а именно
            # подмена: настоящий сайт не живёт на 0.0.0.0 или в 192.168/16.
            say "  ${RED}✗${NC} $(pad "${labels[$i]}" 12) ${answers[$i]} ${RED}(заглушка — подмена DNS)${NC}"
            bogus=1
        elif [ -z "$reference" ] || [ "${answers[$i]}" == "$reference" ]; then
            say "  ${GREEN}✓${NC} $(pad "${labels[$i]}" 12) ${answers[$i]}"
        else
            say "  ${YELLOW}·${NC} $(pad "${labels[$i]}" 12) ${answers[$i]} ${YELLOW}(отличается от ${reference})${NC}"
            mismatch=1
        fi
    done

    if [ "$bogus" -eq 1 ]; then
        say "  ${RED}Резолвер отдаёт заглушку — домен подменяется на уровне DNS.${NC}"
        worst 2
    elif [ "$mismatch" -eq 1 ]; then
        # Разные адреса сами по себе ничего не значат: крупные сайты раздают
        # разным резолверам разные точки присутствия. Значение имеет владелец
        # сети — вот его и сверяем.
        dns_ownership_verdict "${answers[@]}"
    fi
    [ "$dead" -eq 1 ] && { say "  ${YELLOW}Часть резолверов не ответила — проверка DNS неполная.${NC}"; worst 1; }
    return 0
}

# Заведомо непригодные ответы: нули, петля, приватные и зарезервированные сети.
# Настоящий публичный сайт по таким адресам не отвечает, поэтому это признак
# подмены, а не разночтения CDN.
is_bogus_ip() {
    local ip="$1"
    case "$ip" in
        0.*|127.*|10.*|192.168.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    esac
    return 1
}

# Вердикт по расхождению адресов: одна AS — обычный CDN, разные AS — подозрение.
# Если владельца выяснить не удалось, расхождение остаётся справкой и НЕ
# повышает тревожность: ложная тревога здесь вреднее пропуска, потому что
# обесценивает все остальные отметки в отчёте.
dns_ownership_verdict() {
    local -a ips=("$@")
    local json orgs
    json=$(printf '{"asn_lookup": %s}' \
        "$(python3 -c 'import json,sys; print(json.dumps([i for i in sys.argv[1:] if i]))' "${ips[@]}")" \
        | timeout 60 python3 "$PROBE" 2>/dev/null)

    # unknown считается наравне с остальным: адрес, владельца которого выяснить
    # не удалось, — это «неизвестно», а не «та же сеть». Молча выбрасывать его
    # из подсчёта значит выдавать зелёный вердикт ровно про тот адрес, который
    # и вызвал подозрение.
    orgs=$(python3 - "$json" <<'PY' 2>/dev/null
import json,sys
try: d=json.loads(sys.argv[1]).get("asn") or {}
except Exception: raise SystemExit
if not d: raise SystemExit
known={v.get("asn") for v in d.values() if v.get("asn")}
unknown=sum(1 for v in d.values() if not v.get("asn"))
name=next((v.get("org") for v in d.values() if v.get("asn")), "")
print(f"{len(known)}|{name}|{unknown}")
PY
)
    if [ -z "$orgs" ]; then
        say "  ${YELLOW}Адреса различаются. Владельца сетей выяснить не удалось,${NC}"
        say "  ${YELLOW}поэтому отличить CDN от подмены здесь нельзя.${NC}"
        worst 1
        return 0
    fi
    local count name unknown; IFS='|' read -r count name unknown <<< "$orgs"
    if [ "${unknown:-0}" -gt 0 ]; then
        say "  ${YELLOW}Для ${unknown} из адресов владельца выяснить не удалось —${NC}"
        say "  ${YELLOW}отличить CDN от подмены по имеющимся данным нельзя.${NC}"
        worst 1
    elif [ "$count" -le 1 ]; then
        say "  ${GREEN}Разные адреса одной сети (${name}) — обычное поведение CDN.${NC}"
    else
        say "  ${RED}Адреса принадлежат РАЗНЫМ сетям (${count}) — вероятна подмена DNS.${NC}"
        worst 2
    fi
}

check_local_tls() {
    local host="$1" port="$2" label="$3" out subject issuer days alpn
    # tr -d '\0' обязателен: openssl примешивает в вывод нулевые байты, и bash
    # на каждой подстановке печатает предупреждение поверх нашей таблицы.
    out=$(echo | timeout 12 openssl s_client -connect "127.0.0.1:$port" \
          -servername "$host" -alpn h2,http/1.1 2>/dev/null | tr -d '\0')
    if [ -z "$out" ] || ! grep -qa "BEGIN CERTIFICATE" <<< "$out"; then
        say "  ${RED}✗${NC} $(pad "$label" 22) TLS не установился локально"
        worst 1; return
    fi
    subject=$(grep -a -m1 "^subject=" <<< "$out" | sed 's/subject=//; s/^ *//')
    issuer=$(grep -a -m1 "^issuer=" <<< "$out" | sed 's/issuer=.*CN *= *//; s/^ *//')
    alpn=$(grep -a -m1 "^ALPN protocol:" <<< "$out" | sed 's/ALPN protocol: //')

    # Срок действия — частая причина «внезапной блокировки», которая на деле
    # просроченный сертификат. Отделяем одно от другого сразу.
    local end epoch now
    end=$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' <<< "$out" \
          | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$end" ]; then
        epoch=$(date -d "$end" +%s 2>/dev/null); now=$(date +%s)
        [ -n "$epoch" ] && days=$(( (epoch - now) / 86400 ))
    fi

    local warn=""
    if [ -n "${days:-}" ] && [ "$days" -lt 14 ]; then
        warn=" ${YELLOW}(истекает через ${days} дн.)${NC}"; worst 1
    fi
    say "  ${GREEN}✓${NC} $(pad "$label" 22) ${subject:-?}, $issuer, ALPN ${alpn:-нет}${warn}"
}

check_listeners() {
    local port="$1" label="$2"
    if ss -tlnH "sport = :$port" 2>/dev/null | grep -q .; then
        say "  ${GREEN}✓${NC} $(pad "$label" 22) слушает :$port"
    else
        say "  ${RED}✗${NC} $(pad "$label" 22) НИКТО не слушает :$port"
        say "      ${YELLOW}Это отказ службы, а не блокировка — внешние проверки ниже${NC}"
        say "      ${YELLOW}тоже покажут недоступность, но причина здесь.${NC}"
        worst 2
    fi
}

# ---------------------------------------------------------------------------
# УРОВНИ 2 И 3 — ВНЕШНИЕ ПЛОЩАДКИ
# ---------------------------------------------------------------------------
run_probe() {
    local payload="$1" out
    [ -f "$PROBE" ] || { echo '{"fatal":"модуль проб не найден"}'; return; }
    out=$(printf '%s' "$payload" | timeout 300 python3 "$PROBE" 2>/dev/null)
    # Модуль печатает свой {"fatal":...} и выходит с ненулевым кодом. Прежний
    # "|| echo" дописывал второй JSON следом, и склейка переставала читаться —
    # причина сбоя терялась ровно тогда, когда была нужнее всего.
    if [ -n "$out" ]; then printf '%s' "$out"
    else echo '{"fatal":"модуль проб не выдал результата"}'; fi
}

render_checkhost() {
    local json="$1"
    section "ВИДИМОСТЬ ИЗ РФ: датацентры (check-host.net)"
    local rows
    rows=$(python3 - "$json" <<'PY' 2>/dev/null
import json,sys
d=json.loads(sys.argv[1]).get("checkhost") or {}
if not d: print("НЕТ|—|нет данных"); raise SystemExit
for target,res in d.items():
    if "error" in res:
        print(f"ОШИБКА|{target}|{res['error']}"); continue
    for node,r in sorted(res.get("nodes",{}).items()):
        print(f"{'OK' if r['ok'] else 'FAIL'}|{target} через {node}|{r['detail']}")
PY
)
    if [ -z "$rows" ]; then
        say "  ${YELLOW}?${NC} площадка не ответила — уровень не выполнен"; worst 1; return
    fi
    local st what detail
    while IFS='|' read -r st what detail; do
        [ -z "$st" ] && continue
        case "$st" in
            OK)   say "  ${GREEN}✓${NC} $(pad "$what" 34) $(sanitize "$detail")" ;;
            FAIL) say "  ${RED}✗${NC} $(pad "$what" 34) $(sanitize "$detail")"; worst 2 ;;
            *)    say "  ${YELLOW}?${NC} $(pad "$what" 34) $(sanitize "$detail")"; worst 1 ;;
        esac
    done <<< "$rows"
}

render_atlas() {
    local json="$1"
    section "РАДАР ТСПУ: домашние и мобильные сети РФ"
    local rows
    rows=$(python3 - "$json" <<'PY' 2>/dev/null
import json,sys
a=json.loads(sys.argv[1]).get("atlas") or {}
if not a: print("SKIP|радар не запускался|"); raise SystemExit
if "error" in a:
    kind = "CRED" if a.get("credits") else "SKIP"
    print(f"{kind}|{a['error']}|{'настраивается в меню' if a.get('configurable') else ''}")
    raise SystemExit
req=a.get("requested") or 0
got=a.get("total") or 0
if req and got < req:
    print(f"PART|получено {got} проб из {req} запрошенных|остальные не ответили")
for group,title in (("home","домашние/мобильные"),("other","прочие сети")):
    rows=a.get(group) or []
    if not rows: continue
    ok=sum(1 for r in rows if r["ok"])
    print(f"{'HOME' if group=='home' else 'HEAD'}|{title}|{ok}|{len(rows)}")
    for r in rows:
        who=r.get("operator") or (f"AS{r['asn']}" if r.get("asn") else "сеть неизвестна")
        print(f"{'OK' if r['ok'] else 'FAIL'}|  проба {r['probe']}, {who}|{r['detail']}")
PY
)
    if [ -z "$rows" ]; then
        say "  ${YELLOW}?${NC} радар не дал результата"; worst 1; return
    fi

    local st what detail extra home_ok=-1 home_total=0
    while IFS='|' read -r st what detail extra; do
        [ -z "$st" ] && continue
        case "$st" in
            # Домашняя группа считается отдельно: вердикт по ней ниже, а не
            # по каждой пробе. Одна молчащая проба — обычное дело (её могли
            # выключить из розетки), провал всей группы — совсем другое.
            HOME) home_ok="$detail"; home_total="$extra"
                  say "  ${CYAN}$what:${NC} успешных $detail из $extra" ;;
            HEAD) say "  ${CYAN}$what:${NC} успешных $detail из $extra" ;;
            OK)   say "  ${GREEN}✓${NC} $(pad "$what" 34) $(sanitize "$detail")" ;;
            FAIL) say "  ${RED}✗${NC} $(pad "$what" 34) $(sanitize "$detail")" ;;
            PART) say "  ${YELLOW}?${NC} $what — $detail"
                  say "  ${YELLOW}Вывод по домашним сетям тем менее надёжен, чем${NC}"
                  say "  ${YELLOW}меньше проб ответило.${NC}"
                  worst 1 ;;
            SKIP) say "  ${YELLOW}?${NC} $what ${detail:+($detail)}"
                  say "  ${YELLOW}Радар — единственный уровень, который видит фильтрацию${NC}"
                  say "  ${YELLOW}у домашнего абонента. Без него вывод неполон.${NC}"
                  worst 1 ;;
            # Нулевой баланс — самая частая причина неработающего радара у
            # нового аккаунта, и она не чинится настройками. Подсказываем, как
            # получить кредиты, иначе пользователь ищет ошибку в ключе.
            CRED) say "  ${YELLOW}?${NC} $what"
                  say "  ${YELLOW}Кредиты начисляются за размещение пробы RIPE Atlas${NC}"
                  say "  ${YELLOW}либо переводом от другого участника. Разместить пробу —${NC}"
                  say "  ${YELLOW}пункт «Проба RIPE Atlas» в этом же меню; она даёт около${NC}"
                  say "  ${YELLOW}21 600 кредитов в сутки при цене замера в 200.${NC}"
                  say "  ${YELLOW}Остальные два уровня проверки при этом работают.${NC}"
                  worst 1 ;;
        esac
    done <<< "$rows"

    # Вердикт по домашним сетям. Датацентровый узел может видеть сервер
    # прекрасно ровно тогда, когда домашний абонент не подключается вовсе —
    # ради этого случая радар и существует, и занижать его сигнал до
    # «частично» значит терять единственное, что он умеет показывать.
    if [ "$home_ok" -ge 0 ] 2>/dev/null && [ "$home_total" -gt 0 ]; then
        if [ "$home_ok" -eq 0 ]; then
            say "  ${RED}Ни одна проба в домашних и мобильных сетях РФ не установила TLS.${NC}"
            say "  ${RED}Это характерный признак фильтрации у операторов связи.${NC}"
            worst 2
        elif [ "$home_ok" -lt "$home_total" ]; then
            say "  ${YELLOW}Часть домашних сетей не подключилась — блокировка возможна${NC}"
            say "  ${YELLOW}в отдельных регионах или у отдельных операторов.${NC}"
            worst 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# ОТПРАВКА В TELEGRAM
# ---------------------------------------------------------------------------
send_telegram() {
    local text="$1" token="" ids=""
    if [ ! -f "$BOTS_ENV" ]; then
        say "\n${YELLOW}Telegram: боты не установлены, отчёт не отправлен.${NC}"; return
    fi
    token=$(grep -m1 -oP '^COMBINED_BOT_TOKEN=\K.*' "$BOTS_ENV" 2>/dev/null)
    [ -z "$token" ] && token=$(grep -m1 -oP '^TELEMT_BOT_TOKEN=\K.*' "$BOTS_ENV" 2>/dev/null)
    ids=$(grep -m1 -oP '^ADMIN_IDS=\K.*' "$BOTS_ENV" 2>/dev/null | tr -d '"' | tr ',' ' ')
    if [ -z "$token" ] || [ -z "$ids" ]; then
        say "\n${YELLOW}Telegram: нет токена или ADMIN_IDS в .env — не отправлено.${NC}"; return
    fi

    local sent=0 id code
    for id in $ids; do
        # Телеграм режет сообщения длиннее 4096 символов; отправляем хвост,
        # где находится итог, а не начало с заголовками.
        code=$(curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' \
            -X POST "https://api.telegram.org/bot${token}/sendMessage" \
            --data-urlencode "chat_id=${id}" \
            --data-urlencode "text=$(printf '%s' "$text" | tail -c 7000 | python3 -c '
import sys
# Обрезаем по СИМВОЛАМ: отчёт почти весь кириллический, а байтовая обрезка
# рвёт многобайтовый символ пополам, и Telegram отвергает такое сообщение
# с 400 — ровно на длинных отчётах, где проблем больше всего.
sys.stdout.write(sys.stdin.read(errors="ignore")[-3900:])')" 2>/dev/null)
        [ "$code" == "200" ] && sent=$((sent + 1))
    done
    if [ "$sent" -gt 0 ]; then
        say "\n${GREEN}Telegram: отчёт отправлен ($sent получателей).${NC}"
    else
        say "\n${YELLOW}Telegram: отправить не удалось (проверьте токен и ADMIN_IDS).${NC}"
    fi
}

# ---------------------------------------------------------------------------
# ГЛАВНЫЙ ПРОГОН
# ---------------------------------------------------------------------------
run_check() {
    local mode="$1" custom_domain="${2:-}" to_telegram="${3:-no}"
    load_conf

    local own_ip; own_ip=$(detect_own_ip)
    say "${CYAN}======================================================${NC}"
    say "${CYAN}   🧪  ПРОВЕРКА ДОСТУПНОСТИ ИЗ РОССИИ  🧪${NC}"
    say "${CYAN}======================================================${NC}"
    say "Сервер: ${own_ip:-адрес не определён}   $(date '+%Y-%m-%d %H:%M:%S %Z')"

    local -a targets=() ; local atlas_domain="" atlas_port=443

    if [ "$mode" == "stack" ]; then
        if [ -z "$DOMAIN_PANEL" ]; then
            say "${RED}Стек telemt не настроен (/etc/vsm/telemt.conf пуст).${NC}"
            say "${YELLOW}Проверьте произвольный домен или установите стек.${NC}"
            WORST=3; return
        fi
        section "СОБСТВЕННЫЙ СТЕК (локально)"
        check_listeners 443 "панель/REALITY"
        [ -n "$TELEMT_PORT" ] && check_listeners "$TELEMT_PORT" "telemt (MTProto)"
        [ -n "$PANEL_PORT" ]  && check_listeners "$PANEL_PORT"  "telemt_panel"
        check_local_tls "$DOMAIN_PANEL" 443 "TLS панели"
        [ -n "$PANEL_PORT" ] && check_local_tls "$DOMAIN_REALITY" "$PANEL_PORT" "TLS telemt_panel"

        check_dns "$DOMAIN_PANEL" "$own_ip"
        [ -n "$DOMAIN_REALITY" ] && check_dns "$DOMAIN_REALITY" "$own_ip"

        targets+=("${DOMAIN_PANEL}:443")
        [ -n "$TELEMT_PORT" ] && targets+=("${DOMAIN_PANEL}:${TELEMT_PORT}")
        [ -n "$PANEL_PORT" ] && [ -n "$DOMAIN_REALITY" ] && targets+=("${DOMAIN_REALITY}:${PANEL_PORT}")
        atlas_domain="$DOMAIN_PANEL"
    else
        # Форма домена проверяется до вызова dig: строка, начинающаяся с
        # дефиса, будет разобрана dig как собственный флаг, и проверка молча
        # уйдёт в нештатный режим вместо диагностики блокировки.
        # Список запрещённого, а не разрешённого: белый список из латиницы
        # отсекал бы кириллические домены (хост.рф), которые dig разбирает
        # штатно, переводя в punycode. Отсекаем ровно опасное — ведущий дефис,
        # пробелы, метасимволы оболочки — и требуем осмысленную форму имени.
        if [[ "$custom_domain" == -* ]] \
           || [[ "$custom_domain" =~ [[:space:]/\\\$\;\&\|\<\>\(\)\"\'\`] ]] \
           || [[ "$custom_domain" == *..* ]] \
           || [[ "$custom_domain" != *.* ]] \
           || [ "${#custom_domain}" -gt 253 ]; then
            say "${RED}Недопустимое имя домена: «$custom_domain».${NC}"
            say "${YELLOW}Ожидается имя вида example.com — буквы, цифры, точки и дефисы.${NC}"
            WORST=3; return
        fi
        atlas_domain="$custom_domain"
        section "ПРОВЕРЯЕМЫЙ ДОМЕН"
        say "  $custom_domain"
        # Эталон не передаём: правильный адрес чужого домена нам неизвестен.
        check_dns "$custom_domain" ""
        targets+=("${custom_domain}:443")
    fi

    # Оба уровня — одним вызовом: они выполняются параллельно внутри модуля,
    # а два отдельных запуска сложили бы их ожидания.
    say "\n${YELLOW}Опрашиваю внешние точки наблюдения, это до 3 минут...${NC}"
    local payload probe_json
    # Ключ передаётся через окружение, а НЕ аргументом: /proc/<pid>/cmdline
    # читает любой локальный пользователь, а /proc/<pid>/environ — только
    # владелец процесса. Права 600 на конфиге не спасали бы от ps aux.
    payload=$(CC_RIPE_KEY="${RIPE_API_KEY:-}" python3 -c '
import json,os,sys
try: probes=int(sys.argv[4])
except ValueError: probes=10
print(json.dumps({"checkhost_targets": sys.argv[1].split(),
                  "atlas_domain": sys.argv[2], "atlas_port": int(sys.argv[3]),
                  "ripe_key": os.environ.get("CC_RIPE_KEY",""), "atlas_probes": probes}))' \
        "${targets[*]}" "$atlas_domain" "$atlas_port" "${ATLAS_PROBES:-10}")
    probe_json=$(run_probe "$payload")

    if grep -q '"fatal"' <<< "$probe_json"; then
        say "\n${RED}Внешние проверки не выполнены: $(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("fatal",""))' "$probe_json" 2>/dev/null)${NC}"
        worst 3
    else
        render_checkhost "$probe_json"
        render_atlas "$probe_json"
    fi

    say "\n${CYAN}======================================================${NC}"
    case "$WORST" in
        0) say "${GREEN}ИТОГ: признаков блокировки не обнаружено.${NC}" ;;
        1) say "${YELLOW}ИТОГ: доступность частичная либо проверена не полностью.${NC}"
           say "${YELLOW}Смотрите отметки ? и ✗ выше — там причина.${NC}" ;;
        2) say "${RED}ИТОГ: сервер не виден с части точек наблюдения в РФ.${NC}" ;;
        3) say "${RED}ИТОГ: проверка не выполнена, данных нет.${NC}" ;;
    esac
    # Формулировка намеренно осторожная: ни один набор точек наблюдения не
    # покрывает всю страну, блокировки регионально неоднородны, и «чисто»
    # здесь означает лишь отсутствие признаков на проверенных сетях.
    say "${CYAN}======================================================${NC}"

    [ "$to_telegram" == "yes" ] && send_telegram "$REPORT"
    return 0
}

# ---------------------------------------------------------------------------
# КЛЮЧ RIPE ATLAS
# ---------------------------------------------------------------------------
set_ripe_key() {
    echo -e "\n${CYAN}--- Ключ RIPE Atlas ---${NC}"
    echo -e "${YELLOW}Радар ТСПУ работает через пробы RIPE Atlas в сетях РФ."
    echo -e "Ключ создаётся бесплатно: atlas.ripe.net -> Get Started ->"
    echo -e "API Keys -> Create (право «Schedule a new measurement»).${NC}\n"
    load_conf
    [ -n "$RIPE_API_KEY" ] && echo -e "Текущий ключ: ${GREEN}задан${NC} (${RIPE_API_KEY:0:8}…)"
    # -e включает readline: он сам разбирает bracketed paste терминала, поэтому
    # вставленный ключ и на экране выглядит чисто, и в переменную попадает без
    # обёртки ESC[200~…ESC[201~. Извлечение UUID ниже оставлено подстраховкой —
    # на терминалы и сборки bash, где readline эту обёртку не снимает.
    read -e -r -p "Новый ключ (Enter — оставить как есть): " key
    [ -z "$key" ] && { echo -e "${BLUE}Без изменений.${NC}"; return; }

    # Из введённого вытаскиваем UUID, а не сверяем строку целиком.
    #
    # Терминалы работают в режиме bracketed paste: вставленный текст приходит
    # обёрнутым в ESC[200~ и ESC[201~, и read забирает эти последовательности
    # дословно. Сверка строки целиком отвергала правильно вставленный ключ.
    # Заодно это переживает кавычки, пробелы по краям и приставку «Key ».
    local extracted
    extracted=$(printf '%s' "$key" \
        | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        | head -1)
    if [ -z "$extracted" ]; then
        echo -e "${RED}❌ В введённом тексте нет ключа RIPE Atlas.${NC}"
        echo -e "${YELLOW}   Ожидается UUID вида 1b2c3d4e-5f60-7a8b-9c0d-1e2f3a4b5c6d.${NC}"
        echo -e "${YELLOW}   Ключ не сохранён, прежнее значение осталось.${NC}"
        return
    fi
    key="$extracted"

    mkdir -p /etc/vsm; chmod 700 /etc/vsm
    { echo "# Создано VSM, не редактируйте вручную."
      printf 'RIPE_API_KEY=%q\n' "$key"
      printf 'ATLAS_PROBES=%q\n' "${ATLAS_PROBES:-10}"
    } > "$CC_CONF"
    chmod 600 "$CC_CONF"
    # Показываем края распознанного ключа: при кривой вставке видно сразу,
    # что сохранилось не то, а целиком секрет на экран не выносим.
    echo -e "${GREEN}✅ Распознан ключ ${key:0:8}…${key: -4}, сохранён в $CC_CONF (права 600).${NC}"
}

case "${1:-}" in
    --stack)    run_check stack "" "${2:-no}" ; exit $WORST ;;
    --domain)   run_check domain "${2:-}" "${3:-no}" ; exit $WORST ;;
    --set-key)  set_ripe_key ;;
    *) echo "Использование: $0 --stack [yes] | --domain <домен> [yes] | --set-key"
       echo "  третий аргумент yes — отправить отчёт в Telegram"; exit 64 ;;
esac
