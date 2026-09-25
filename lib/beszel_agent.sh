# shellcheck shell=bash
# Агент beszel на этом сервере: железо, службы, диск — в хаб владельца.
#
# ЗАЧЕМ В VSM. Хаб beszel знает все серверы владельца, бот показывает их на
# экране «Серверы». Новый арендованный сервер должен появляться там сразу, а
# агент до сих пор ставили руками — и на одном из серверов его не было вовсе.
#
# СТАВИТ ОФИЦИАЛЬНЫЙ УСТАНОВЩИК beszel (supplemental/scripts/install-agent.sh).
# Бинарь он сверяет по контрольной сумме сам, заводит пользователя beszel,
# службу beszel-agent и суточный таймер обновления. Свой установщик мы не
# пишем: он разошёлся бы с авторским при первом же изменении. Ключи —
# -k -t -url --auto-update true, без вопросов (проверено по тексту 24.09.2026).
#
# СВЯЗЬ С ХАБОМ — ТОЛЬКО WebSocket. Агент слушает ещё и порт 45876 для
# старого режима, где хаб приходит к нему сам по SSH. Этот порт фаервол
# держит закрытым, и открывать его незачем: агент сам ходит к хабу наружу.
# Поэтому проверка ждёт в журнале именно «WebSocket connected». Урок стенда:
# там агент получал от хаба 401 и всё равно «работал» — хаб стоит на той же
# машине и дотягивался до него по SSH через петлю. С удалённого сервера так
# не выйдет.
#
# ЦЕНА. Токен на время установки виден в списке процессов (так устроен
# установщик: только аргументы), а потом лежит в юните с правами 644. Это
# токен регистрации агента, а не учётная запись хаба.

BESZEL_AGENT_INSTALLER_URL="${BESZEL_AGENT_INSTALLER_URL:-https://raw.githubusercontent.com/henrygd/beszel/main/supplemental/scripts/install-agent.sh}"
BESZEL_AGENT_UNIT="${BESZEL_AGENT_UNIT:-/etc/systemd/system/beszel-agent.service}"
BESZEL_AGENT_BIN="${BESZEL_AGENT_BIN:-/opt/beszel-agent/beszel-agent}"
BESZEL_AGENT_WAIT="${BESZEL_AGENT_WAIT:-40}"

_ba_fail() { echo -e "${RED:-}❌ $*${NC:-}" >&2; return 1; }

beszel_agent_installed() { [ -x "$BESZEL_AGENT_BIN" ] && [ -f "$BESZEL_AGENT_UNIT" ]; }

beszel_agent_hub_url() {
    [ -r "$BESZEL_AGENT_UNIT" ] || return 1
    sed -n 's/^Environment="HUB_URL=\(.*\)"$/\1/p' "$BESZEL_AGENT_UNIT" | head -1
}

beszel_agent_version() {
    "$BESZEL_AGENT_BIN" -v 2>/dev/null | awk '{print $2}'
}

# ----------------------------------------------------------------------
# Связь с хабом по журналу ТЕКУЩЕГО запуска службы (по InvocationID —
# старые записи прошлых запусков не должны отвечать за нынешний):
#   ws      — «WebSocket connected», связь есть;
#   denied  — хаб отверг токен (401);
#   ssh     — связь только по SSH: хаб на этой же машине;
#   fail    — WebSocket не соединился по другой причине;
#   wait    — пока ни того ни другого.
# ----------------------------------------------------------------------
beszel_agent_link() {
    local inv log last
    inv="$(systemctl show -p InvocationID --value beszel-agent 2>/dev/null)"
    [ -n "$inv" ] || { echo "wait"; return; }
    log="$(journalctl _SYSTEMD_INVOCATION_ID="$inv" -o cat --no-pager 2>/dev/null)"
    last="$(grep -E 'WebSocket connected|WebSocket connection failed|SSH connection established|Disconnected from hub' <<< "$log" | tail -1)"
    case "$last" in
        *"WebSocket connected"*)       echo "ws" ;;
        *"status code: 401"*)          echo "denied" ;;
        *"SSH connection established"*) echo "ssh" ;;
        *"WebSocket connection failed"*|*"Disconnected"*) echo "fail" ;;
        *) echo "wait" ;;
    esac
}

# ----------------------------------------------------------------------
# Хаб beszel на ЭТОМ сервере: есть ли и по какому адресу его видно снаружи.
#
# Адрес не хранится нигде, кроме конфига nginx, который отдаёт хаб наружу, —
# его и читаем: server_name и порт listen из файла, где proxy_pass ведёт на
# адрес хаба. Адрес хаба — из его же ExecStart (с учётом drop-in: там на 179
# хаб переведён на петлю). Выдумать адрес, которого nginx не отдаёт, хуже,
# чем сказать «наружу не выпущен».
#   beszel_hub_listen  → 127.0.0.1:8090
#   beszel_hub_url     → https://panel.example.com:8445 ; пусто — не выпущен
# ----------------------------------------------------------------------
beszel_hub_installed() {
    [ -n "$(systemctl show -p FragmentPath --value beszel-hub 2>/dev/null)" ]
}

beszel_hub_listen() {
    local exec addr
    exec="$(systemctl show -p ExecStart --value beszel-hub 2>/dev/null)"
    addr="$(grep -oE -- '--http[ =]"?[^ ";]+' <<< "$exec" | tail -1)"
    addr="${addr#--http}"; addr="${addr# }"; addr="${addr#=}"; addr="${addr#\"}"
    echo "${addr:-0.0.0.0:8090}"
}

beszel_hub_url() {
    local port f conf name lport
    port="$(beszel_hub_listen)"; port="${port##*:}"
    for f in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
        [ -f "$f" ] || continue
        conf="$(cat "$f" 2>/dev/null)"
        grep -qE "proxy_pass[[:space:]]+http://(127\.0\.0\.1|localhost):${port}[;/]" <<< "$conf" || continue
        name="$(grep -m1 -oP '^\s*server_name\s+\K[^\s;]+' <<< "$conf")"
        lport="$(grep -m1 -oP '^\s*listen\s+\K[0-9]+(?=\s+ssl)' <<< "$conf")"
        [ -n "$name" ] && [ -n "$lport" ] || continue
        if [ "$lport" = "443" ]; then echo "https://${name}"; else echo "https://${name}:${lport}"; fi
        return 0
    done
    return 1
}

# Одна строка для меню.
beszel_agent_state() {
    if ! beszel_agent_installed; then
        echo "не установлен"
        return
    fi
    if ! systemctl is-active --quiet beszel-agent; then
        echo "служба не работает"
        return
    fi
    case "$(beszel_agent_link)" in
        ws)     echo "работает, связь с хабом есть" ;;
        denied) echo "хаб отверг токен" ;;
        ssh)    echo "связь только по SSH (хаб на этой машине)" ;;
        fail)   echo "не может достучаться до хаба" ;;
        *)      echo "работает, связь ещё не установлена" ;;
    esac
}

# ----------------------------------------------------------------------
# Поставить или переподключить: beszel_agent_install <хаб> <ключ> <токен>
# ----------------------------------------------------------------------
beszel_agent_install() {
    local hub="${1%/}" key="$2" token="$3" code
    case "$hub" in
        https://*|http://*) ;;
        *) _ba_fail "адрес хаба должен начинаться с https:// — получено: ${hub:-пусто}"; return 1 ;;
    esac
    case "$key" in
        ssh-ed25519\ *) ;;
        *) _ba_fail "ключ хаба должен начинаться с ssh-ed25519"; return 1 ;;
    esac
    [ -n "$token" ] || { _ba_fail "пустой токен"; return 1; }

    # Хаб недоступен — ставить агента, который никуда не достучится, незачем.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$hub/api/health" 2>/dev/null)"
    [ "$code" = "200" ] || { _ba_fail "хаб не отвечает: $hub/api/health → ${code:-нет ответа}"; return 1; }

    # Агент уже стоит — переподключаем, не скачивая заново. Установщик
    # beszel качает бинарь и файл сумм при КАЖДОМ запуске, а GitHub с
    # серверов отвечает не на каждое соединение: 25.09.2026 на одном из серверов файл сумм
    # дважды не скачался за 10 секунд, и смена хаба у работающего агента
    # той же версии упала на сети, которая для неё не нужна вовсе.
    if beszel_agent_installed; then
        # Работающий агент не оставляем без хаба: не подключился к новому —
        # возвращаем прежний юнит.
        local backup="${BESZEL_AGENT_UNIT}.vsm-before"
        cp -p "$BESZEL_AGENT_UNIT" "$backup" || { _ba_fail "не удалось сохранить копию юнита"; return 1; }
        _beszel_agent_set_env "$hub" "$key" "$token" || { rm -f "$backup"; return 1; }
        if _beszel_agent_verify; then
            rm -f "$backup"
            return 0
        fi
        mv -f "$backup" "$BESZEL_AGENT_UNIT"
        systemctl daemon-reload
        systemctl restart beszel-agent
        _ba_fail "агент возвращён к прежнему хабу: $(beszel_agent_hub_url)"
        return 1
    fi
    _beszel_agent_run_installer "$hub" "$key" "$token" || return 1
    _beszel_agent_verify
}

# Три строки Environment в юните — через python, а не sed: в ключе хаба
# base64 с «/» и «+», которые sed понял бы как разделитель и шаблон.
_beszel_agent_set_env() {
    local hub="$1" key="$2" token="$3"
    BA_HUB="$hub" BA_KEY="$key" BA_TOKEN="$token" python3 - "$BESZEL_AGENT_UNIT" <<'PY' || { _ba_fail "не удалось переписать $BESZEL_AGENT_UNIT"; return 1; }
import os, re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
for name, env in (("HUB_URL", "BA_HUB"), ("KEY", "BA_KEY"), ("TOKEN", "BA_TOKEN")):
    line = f'Environment="{name}={os.environ[env]}"'
    new, n = re.subn(rf'^Environment="{name}=.*"$', lambda m: line, text, flags=re.M)
    if n == 0:
        new = re.sub(r"^\[Service\]$", lambda m: m.group(0) + "\n" + line, text, count=1, flags=re.M)
    text = new
tmp = path + ".vsm-tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(text)
os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
PY
    echo -e "${C_DESC:-}   Агент уже стоит — меняю только адрес хаба, ключ и токен.${NC:-}"
}

_beszel_agent_run_installer() {
    local hub="$1" key="$2" token="$3" tmp
    tmp="$(mktemp /tmp/vsm-beszel-agent.XXXXXX.sh)" || return 1
    if ! curl -fsSL --max-time 60 "$BESZEL_AGENT_INSTALLER_URL" -o "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        _ba_fail "не удалось скачать установщик beszel: $BESZEL_AGENT_INSTALLER_URL"; return 1
    fi
    declare -F upstream_fingerprint >/dev/null 2>&1 \
        && upstream_fingerprint "$BESZEL_AGENT_INSTALLER_URL" "$tmp"

    # </dev/null: на случай вопроса, о котором мы не знаем, — установщик
    # получит конец ввода и пойдёт по умолчанию, а не повиснет.
    if ! sh "$tmp" -k "$key" -t "$token" -url "$hub" --auto-update true < /dev/null; then
        rm -f "$tmp"
        _ba_fail "установщик beszel завершился с ошибкой"; return 1
    fi
    rm -f "$tmp"
}

# Перезапуск наш — чтобы проверка смотрела на запуск с новыми ключами:
# установщик перезапускает службу не всегда, а правка юнита — никогда.
_beszel_agent_verify() {
    local i link groups
    systemctl daemon-reload
    systemctl restart beszel-agent || { _ba_fail "служба beszel-agent не запускается"; return 1; }

    for ((i = 0; i < BESZEL_AGENT_WAIT; i++)); do
        link="$(beszel_agent_link)"
        case "$link" in ws|denied) break ;; esac
        sleep 1
    done
    case "$link" in
        ws)
            echo -e "${GREEN:-}✔ Агент beszel $(beszel_agent_version) подключился к хабу.${NC:-}"
            groups="$(id -nG beszel 2>/dev/null)"
            if grep -qw docker <<< "$groups"; then
                echo -e "${YELLOW:-}❗  Установщик добавил пользователя beszel в группу docker —"
                echo -e "    это права, равные root. Так делает сам beszel ради статистики контейнеров.${NC:-}"
            fi
            return 0 ;;
        denied)
            _ba_fail "хаб отверг токен (401). Возьмите токен в хабе: «Добавить систему» —"
            _ba_fail "    или общий токен в «Настройки → Токены и отпечатки»."
            return 1 ;;
        *)
            _ba_fail "за ${BESZEL_AGENT_WAIT} с агент не подключился к хабу по WebSocket:"
            journalctl -u beszel-agent -n 5 -o cat --no-pager 2>/dev/null | sed 's/^/    /' >&2
            return 1 ;;
    esac
}

beszel_agent_remove() {
    local tmp
    tmp="$(mktemp /tmp/vsm-beszel-agent.XXXXXX.sh)" || return 1
    if ! curl -fsSL --max-time 60 "$BESZEL_AGENT_INSTALLER_URL" -o "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        _ba_fail "не удалось скачать установщик beszel"; return 1
    fi
    sh "$tmp" -u < /dev/null
    rm -f "$tmp"
    if beszel_agent_installed || systemctl is-active --quiet beszel-agent 2>/dev/null; then
        _ba_fail "агент всё ещё на месте"; return 1
    fi
    echo -e "${GREEN:-}✔ Агент beszel удалён.${NC:-}"
}
