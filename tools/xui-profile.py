#!/usr/bin/env python3
"""
ШАБЛОН НАСТРОЕК 3x-ui: снять с одного сервера, наложить на свежую установку.

    python3 tools/xui-profile.py export  [--out ФАЙЛ] [--name ИМЯ]
    python3 tools/xui-profile.py apply   [--domain Д] [--reality-domain Д]
                                         [--name ИМЯ] [--ip АДРЕС]
                                         [--profile ФАЙЛ] [--dry-run]
    python3 tools/xui-profile.py show    [--profile ФАЙЛ]

ЗАЧЕМ. Установщик 3x-ui-pro ставит голую панель: четыре входящих с
названиями «флаг + протокол», подписка без названия, контактов и правил.
Владелец доводит её руками — и на следующем сервере делает то же заново.
Шаблон переносит эти правки.

ЧТО ПЕРЕНОСИТСЯ, А ЧТО НЕТ. Настройки 3x-ui делятся на две части.

  Вкус владельца — переносим: оформление и правила подписок, названия и
  порядок входящих, sniffing, параметры транспорта, хосты, а также входящие,
  которых установщик не создаёт (hy2, awg), — по образцу.

  Привязанное к установке — оставляем от установщика: порты и пути ws и grpc
  (3x-ui-pro связывает их с nginx, чужие значения разорвали бы эту связь),
  ключи REALITY, секретный путь панели, пути и порт подписки. Клиентов не
  переносим вовсе: это решение владельца, ссылки на новом сервере всё равно
  новые — домены и ключи другие.

  Секреты в шаблон не попадают. Ключи и пароли входящих, которые создаются
  по образцу, генерируются заново.

ПОДСТАНОВКИ. Домены, адрес сервера, флаг страны и имя сервера при снятии
заменяются метками {DOMAIN}, {REALITY_DOMAIN}, {IP}, {FLAG}, {NAME} — во всём
тексте шаблона разом. Так «🇸🇪 adkrw My1Cent» становится «{FLAG} adkrw {NAME}»,
а на новом сервере — его флагом и его именем.

КАК НАКЛАДЫВАЕТСЯ. Прямо в базу при остановленной панели — так же пишет в неё
сам установщик 3x-ui-pro. Перед наложением снимается копия базы; после —
панель запускается и проверяется фактом: служба жива, xray запущен, входящих
столько, сколько должно быть. Не прошло — база возвращается из копии.

ГЛАВНЫЙ РИСК — СМЕНА ВЕРСИИ. Шаблон хранит версию 3x-ui, с которой снят.
Столбцы, которых в новой базе нет, отбрасываются с предупреждением, новые
получают умолчания — поэтому проверка фактом после наложения обязательна.
"""

import argparse
import base64
import json
import os
import re
import secrets
import shutil
import sqlite3
import string
import subprocess
import sys
import time
from pathlib import Path

DB = os.environ.get("XUI_DB", "/etc/x-ui/x-ui.db")
PROFILE = os.environ.get("XUI_PROFILE", "/etc/vsm/xui-profile.json")
BACKUP_DIR = os.environ.get("XUI_PROFILE_BACKUP_DIR", "/var/backups/vsm/xui")
FORMAT = 1

# Метки подстановки. Порядок замены при снятии — от длинного к короткому,
# чтобы домен не зацепило внутри более длинного.
MARKS = ("DOMAIN", "REALITY_DOMAIN", "IP", "FLAG", "NAME")

# Какие входящие создаёт установщик 3x-ui-pro. У них мы берём от установщика
# всё привязанное к установке и накладываем остальное. Прочие роли (hy2, awg)
# создаются по образцу целиком.
INSTALLER_ROLES = ("vless/tcp/reality", "vless/ws/none", "vless/xhttp/none", "trojan/grpc/none")
# Хвост названия, который ставит установщик: «флаг reality», «флаг ws» и т.д.
# По нему при снятии угадываем имя сервера.
INSTALLER_SUFFIX = {"vless/tcp/reality": "reality", "vless/ws/none": "ws",
                    "vless/xhttp/none": "xhttp", "trojan/grpc/none": "trojan-grpc"}

# Поля потока, которые принадлежат установке, а не вкусу: пути (связаны с
# nginx), имена хостов (подставит установщик), ключи REALITY.
INSTANCE_STREAM = {
    "vless/tcp/reality": [("realitySettings", "privateKey"), ("realitySettings", "shortIds"),
                          ("realitySettings", "serverNames"), ("realitySettings", "target"),
                          ("realitySettings", "dest"), ("realitySettings", "mldsa65Seed"),
                          ("realitySettings", "settings", "publicKey"),
                          ("realitySettings", "settings", "mldsa65Verify")],
    "vless/ws/none": [("wsSettings", "path"), ("wsSettings", "host")],
    "vless/xhttp/none": [("xhttpSettings", "path"), ("xhttpSettings", "host")],
    "trojan/grpc/none": [("grpcSettings", "serviceName"), ("grpcSettings", "authority")],
}
# Столбцы входящего, привязанные к установке или к накопленной статистике.
INSTANCE_COLUMNS = {"id", "port", "listen", "tag", "up", "down", "total",
                    "last_traffic_reset_time", "node_id", "origin_node_guid"}

# Настройки панели, которые переносим. Список разрешённых, а не запрещённых:
# завтра в панели появится новый ключ с токеном, и чёрный список его бы
# пропустил, а белый — нет.
SETTINGS_PREFIX = "sub"
SETTINGS_EXTRA = {"remarkModel", "remarkTemplate", "timeLocation", "datepicker", "pageSize",
                  "expireDiff", "trafficDiff", "sessionMaxAge", "tgLang",
                  "restartXrayOnClientDisable", "realityScanCandidates", "happLinkEnable"}
# Ключи подписки, привязанные к установке: пути, порт, адреса, сертификаты.
SETTINGS_INSTANCE = {"subPort", "subPath", "subJsonPath", "subClashPath", "subURI",
                     "subJsonURI", "subClashURI", "subCertFile", "subKeyFile",
                     "subDomain", "subListen"}

HOST_SKIP = {"id", "inbound_id", "group_id", "created_at", "updated_at", "node_guids"}


def say(msg=""):
    print(msg, flush=True)


def warn(msg):
    print(f"⚠️  {msg}", file=sys.stderr, flush=True)


def die(msg, code=1):
    print(f"❌ {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


# --------------------------------------------------------------- база

def connect(path):
    if not Path(path).is_file():
        die(f"нет базы 3x-ui: {path}")
    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    return c


def columns(c, table):
    return [r[1] for r in c.execute(f"PRAGMA table_info({table})")]


def loads(text):
    if text in (None, ""):
        return None
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return text


def role(protocol, stream):
    stream = stream if isinstance(stream, dict) else {}
    return f"{protocol}/{stream.get('network') or '-'}/{stream.get('security') or 'none'}"


def xui_version():
    try:
        out = subprocess.run([os.environ.get("XUI_BIN", "/usr/local/x-ui/x-ui"), "-v"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        return out.splitlines()[-1] if out else ""
    except Exception:
        return ""


# --------------------------------------------------------------- подстановки

def placeholders(values: dict) -> list:
    """Пары (значение, метка) от длинного значения к короткому."""
    pairs = [(v, "{" + k + "}") for k, v in values.items() if v]
    return sorted(pairs, key=lambda p: -len(p[0]))


def to_marks(text, values):
    for value, mark in placeholders(values):
        text = text.replace(value, mark)
    return text


def from_marks(text, values):
    for key in MARKS:
        mark = "{" + key + "}"
        if not values.get(key):
            # Пустое значение не должно оставить двойной пробел в названии:
            # «{FLAG} {NAME} reality» без имени — «🇸🇪 reality», а не «🇸🇪  reality».
            text = text.replace(" " + mark, "").replace(mark + " ", "")
        text = text.replace(mark, values.get(key) or "")
    return text


def walk_marks(obj, values, forward):
    """Подстановка в каждой строке структуры, а не в JSON-тексте целиком:
    так экранирование JSON не мешает заменам и не ломается ими."""
    fn = to_marks if forward else from_marks
    if isinstance(obj, str):
        return fn(obj, values)
    if isinstance(obj, list):
        return [walk_marks(x, values, forward) for x in obj]
    if isinstance(obj, dict):
        return {k: walk_marks(v, values, forward) for k, v in obj.items()}
    return obj


# --------------------------------------------------------------- снятие

FLAG_RE = re.compile(r"^((?:[\U0001F1E6-\U0001F1FF]{2})|🌐)\s*")


def guess_identity(inbounds):
    """Флаг и имя сервера из названия входящего reality: «🇸🇪 My1Cent reality»."""
    for ib in inbounds:
        r = role(ib["protocol"], loads(ib["stream_settings"]))
        suffix = INSTALLER_SUFFIX.get(r)
        remark = ib["remark"] or ""
        if not suffix or not remark.endswith(suffix):
            continue
        m = FLAG_RE.match(remark)
        flag = m.group(1) if m else ""
        name = remark[len(m.group(0)) if m else 0:-len(suffix)].strip()
        return flag, name
    return "", ""


def export(args):
    c = connect(DB)
    inbounds = [dict(r) for r in c.execute("select * from inbounds order by id")]
    if not inbounds:
        die("в панели нет ни одного входящего — снимать нечего")
    settings = {k: v for k, v in c.execute("select key, value from settings")}

    flag, name = guess_identity(inbounds)
    if args.name is not None:
        name = args.name
    domain = urlhost(settings.get("subURI", "")) or args.domain or ""
    reality = ""
    ip = args.ip or ""
    for ib in inbounds:
        st = loads(ib["stream_settings"]) or {}
        rs = st.get("realitySettings") if isinstance(st, dict) else None
        if rs and rs.get("serverNames"):
            reality = rs["serverNames"][0]
        if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ib["listen"] or ""):
            ip = ip or ib["listen"]
    values = {"DOMAIN": domain, "REALITY_DOMAIN": reality, "IP": ip, "FLAG": flag, "NAME": name}
    missing = [k for k in ("DOMAIN", "REALITY_DOMAIN") if not values[k]]
    if missing:
        die("не определил " + ", ".join(missing) + " — укажите --domain")

    host_cols = columns(c, "hosts")
    hosts_by_inbound = {}
    for h in c.execute("select * from hosts order by inbound_id, sort_order, id"):
        h = dict(h)
        hosts_by_inbound.setdefault(h["inbound_id"], []).append(
            {k: v for k, v in h.items() if k not in HOST_SKIP and k in host_cols})

    seen_roles = set()
    out_inbounds = []
    for ib in inbounds:
        stream = loads(ib["stream_settings"])
        r = role(ib["protocol"], stream)
        if r in seen_roles:
            warn(f"второй входящий роли {r} ({ib['remark']}) пропущен: "
                 "повторить его на новом сервере без своих портов и путей нельзя")
            continue
        seen_roles.add(r)
        settings_json = loads(ib["settings"]) or {}
        if isinstance(settings_json, dict):
            settings_json = strip_secrets(ib["protocol"], settings_json)
        row = {k: v for k, v in ib.items()
               if k not in INSTANCE_COLUMNS and k not in ("settings", "stream_settings", "sniffing")}
        row.update({
            "role": r,
            "port": ib["port"],            # только для ролей по образцу: 443 у hy2
            "listen": ib["listen"],
            "settings": settings_json,
            "stream_settings": strip_stream(r, stream),
            "sniffing": loads(ib["sniffing"]),
            "hosts": hosts_by_inbound.get(ib["id"], []),
        })
        out_inbounds.append(row)

    profile = {
        "format": FORMAT,
        "made_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "xui_version": xui_version(),
        "source": {"FLAG": flag, "NAME": name},
        "settings": {k: v for k, v in sorted(settings.items())
                     if (k.startswith(SETTINGS_PREFIX) or k in SETTINGS_EXTRA)
                     and k not in SETTINGS_INSTANCE},
        "inbounds": out_inbounds,
    }
    profile = walk_marks(profile, values, forward=True)
    # Имя в source должно остаться именем, а не меткой.
    profile["source"] = {"FLAG": flag, "NAME": name}

    leaked = [v for v in (domain, reality, ip) if v and v in json.dumps(profile, ensure_ascii=False)]
    if leaked:
        die("в шаблоне остались адреса сервера после подстановки — снятие прервано")

    out = Path(args.out or PROFILE)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    old = os.umask(0o077)
    try:
        tmp.write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding="utf-8")
    finally:
        os.umask(old)
    tmp.replace(out)
    say(f"✅ Шаблон снят: {out}")
    say(f"   входящих: {len(out_inbounds)}, хостов: "
        f"{sum(len(i['hosts']) for i in out_inbounds)}, настроек: {len(profile['settings'])}")
    say(f"   флаг: {flag or '—'}, имя сервера: {name or '—'}, 3x-ui: {profile['xui_version'] or '?'}")


def urlhost(url):
    m = re.match(r"https?://([^/:?]+)", url or "")
    return m.group(1) if m else ""


# Ключи настроек входящего, которые являются секретами. Их не сохраняем:
# создаваемые по образцу входящие получают новые.
AWG_SECRETS = ("privateKey", "publicKey", "headerProtectionKey")


def strip_secrets(protocol, settings_json):
    s = dict(settings_json)
    s["clients"] = []
    s.pop("peers", None)
    if protocol == "amneziawg" and isinstance(s.get("server"), dict):
        s["server"] = {k: v for k, v in s["server"].items() if k not in AWG_SECRETS}
    return s


def strip_stream(r, stream):
    if not isinstance(stream, dict):
        return stream
    st = json.loads(json.dumps(stream))
    for path in INSTANCE_STREAM.get(r, []):
        pop_path(st, path)
    # Пароль salamander у hy2 — секрет, создаётся заново.
    for item in ((st.get("finalmask") or {}).get("udp") or []):
        if isinstance(item, dict) and isinstance(item.get("settings"), dict):
            item["settings"].pop("password", None)
    # Ключ сертификата — путь к файлу, не секрет, но и не вкус: подставится
    # по домену. Сами пути к сертификату несут домен и уйдут в метку.
    return st


def pop_path(obj, path):
    for key in path[:-1]:
        obj = obj.get(key) if isinstance(obj, dict) else None
        if obj is None:
            return
    if isinstance(obj, dict):
        obj.pop(path[-1], None)


def get_path(obj, path):
    for key in path:
        if not isinstance(obj, dict) or key not in obj:
            return None, False
        obj = obj[key]
    return obj, True


def set_path(obj, path, value):
    for key in path[:-1]:
        obj = obj.setdefault(key, {})
    obj[path[-1]] = value


# --------------------------------------------------------------- наложение

def wg_keypair():
    """
    Ключи WireGuard (x25519) — как у панели и у `xray wg`.

    Своя реализация, а не вызов xray: путь к бинарю меняется от версии к
    версии и от архитектуры, а формула одна и проверяется тестом по
    контрольному вектору RFC 7748.
    """
    priv = bytearray(secrets.token_bytes(32))
    priv[0] &= 248
    priv[31] &= 127
    priv[31] |= 64
    pub = x25519(bytes(priv), (9).to_bytes(32, "little"))
    return base64.b64encode(bytes(priv)).decode(), base64.b64encode(pub).decode()


def x25519(k: bytes, u: bytes) -> bytes:
    """RFC 7748, раздел 5: лестница Монтгомери на кривой 25519."""
    p = 2 ** 255 - 19
    a24 = 121665
    k_int = int.from_bytes(k, "little")
    k_int &= ~7
    k_int &= ~(128 << 8 * 31)
    k_int |= 64 << 8 * 31
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (k_int >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % p, (x2 - z2) % p
        aa, bb = a * a % p, b * b % p
        e = (aa - bb) % p
        c, d = (x3 + z3) % p, (x3 - z3) % p
        da, cb = d * a % p, c * b % p
        x3 = (da + cb) ** 2 % p
        z3 = x1 * (da - cb) ** 2 % p
        x2 = aa * bb % p
        z2 = e * (aa + a24 * e) % p
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def random_token(n, alphabet=string.ascii_letters + string.digits):
    return "".join(secrets.choice(alphabet) for _ in range(n))


def group_id():
    """Как gen_group_id у 3x-ui-pro: 16 знаков из строчных букв и цифр."""
    return random_token(16, string.ascii_lowercase + string.digits)


def free_udp_port(used):
    for _ in range(200):
        port = 20000 + secrets.randbelow(40000)
        if port in used:
            continue
        busy = subprocess.run(["ss", "-Hlun", "sport", "=", f":{port}"], capture_output=True,
                              text=True).stdout.strip() if shutil.which("ss") else ""
        if not busy:
            return port
    die("не нашёл свободный UDP-порт для awg")


def keep_secrets(settings_json, stream, fresh_settings, fresh_stream):
    """
    Входящий по образцу уже есть в базе — например, шаблон накладывают второй
    раз. Секретов в шаблоне нет, и без этого шага повторное наложение стёрло
    бы ключи awg и пароль hy2: входящий остался бы, а подключиться к нему
    было бы нечем. Берём секреты из базы.
    """
    server = fresh_settings.get("server") if isinstance(fresh_settings, dict) else None
    if isinstance(server, dict) and isinstance(settings_json.get("server"), dict):
        for key in AWG_SECRETS:
            if key in server:
                settings_json["server"][key] = server[key]
    old = ((fresh_stream or {}).get("finalmask") or {}).get("udp") if isinstance(fresh_stream, dict) else None
    new = ((stream or {}).get("finalmask") or {}).get("udp") if isinstance(stream, dict) else None
    for i, item in enumerate(new or []):
        if i < len(old or []) and isinstance(item, dict) and isinstance(old[i], dict):
            password = (old[i].get("settings") or {}).get("password")
            if password:
                item.setdefault("settings", {})["password"] = password


def fresh_secrets(r, settings_json, stream):
    """Новые секреты для входящих, создаваемых по образцу."""
    if r.startswith("amneziawg/") and isinstance(settings_json.get("server"), dict):
        priv, pub = wg_keypair()
        settings_json["server"].update({
            "privateKey": priv, "publicKey": pub,
            "headerProtectionKey": base64.b64encode(secrets.token_bytes(32)).decode(),
        })
    if isinstance(stream, dict):
        for item in ((stream.get("finalmask") or {}).get("udp") or []):
            if isinstance(item, dict) and item.get("type") == "salamander":
                item.setdefault("settings", {})["password"] = random_token(16)


def plan_apply(c, profile, values):
    """
    Считает, что записать, ничего не записывая. Возвращает список действий и
    число входящих, которое должно получиться. Отдельно от записи — ради
    --dry-run и ради проверок: логику можно прогнать на копии базы.
    """
    profile = walk_marks(profile, values, forward=False)
    fresh = [dict(r) for r in c.execute("select * from inbounds order by id")]
    by_role = {}
    for ib in fresh:
        by_role.setdefault(role(ib["protocol"], loads(ib["stream_settings"])), ib)
    inbound_cols = set(columns(c, "inbounds"))
    host_cols = set(columns(c, "hosts"))
    used_ports = {ib["port"] for ib in fresh}

    actions = []
    dropped = set()
    for tpl in profile["inbounds"]:
        r = tpl["role"]
        target = by_role.get(r)
        if r in INSTALLER_ROLES and target is None:
            warn(f"установщик не создал входящий {r} — пропускаю «{tpl.get('remark')}»")
            continue
        stream = json.loads(json.dumps(tpl.get("stream_settings")))
        settings_json = json.loads(json.dumps(tpl.get("settings") or {}))
        row = {k: v for k, v in tpl.items()
               if k not in ("role", "hosts", "settings", "stream_settings", "sniffing", "port", "listen")}
        row["sniffing"] = tpl.get("sniffing")

        if target is not None:
            # Своё от установщика: порт, адрес, тег, клиенты и поля потока,
            # связанные с nginx и ключами.
            fresh_stream = loads(target["stream_settings"]) or {}
            for path in INSTANCE_STREAM.get(r, []):
                value, found = get_path(fresh_stream, path)
                if found:
                    set_path(stream, path, value)
                else:
                    pop_path(stream, path)
            fresh_settings = loads(target["settings"]) or {}
            settings_json["clients"] = fresh_settings.get("clients", [])
            if r not in INSTALLER_ROLES:
                keep_secrets(settings_json, stream, fresh_settings, fresh_stream)
            row.update({"settings": settings_json, "stream_settings": stream})
            actions.append(("update", target["id"], row, tpl.get("hosts") or []))
        else:
            fresh_secrets(r, settings_json, stream)
            port = tpl.get("port") or 0
            if r.startswith("amneziawg/"):
                port = free_udp_port(used_ports)
            elif port in used_ports and port:
                warn(f"порт {port} уже занят другим входящим — «{tpl.get('remark')}» пропущен")
                continue
            used_ports.add(port)
            transport = "udp" if r.startswith(("amneziawg/", "hysteria/")) else "tcp"
            row.update({"settings": settings_json, "stream_settings": stream, "port": port,
                        "listen": tpl.get("listen") or "", "tag": f"in-{port}-{transport}",
                        "up": 0, "down": 0, "total": 0})
            actions.append(("insert", None, row, tpl.get("hosts") or []))
        for key in list(row):
            if key not in inbound_cols:
                dropped.add(key)
                row.pop(key)
    for tpl_h in profile["inbounds"]:
        for h in tpl_h.get("hosts") or []:
            for key in list(h):
                if key not in host_cols:
                    dropped.add(f"hosts.{key}")
                    h.pop(key)
    if dropped:
        warn("столбцов нет в этой версии 3x-ui, отброшены: " + ", ".join(sorted(dropped)))

    settings_rows = dict(profile.get("settings") or {})
    expected = len(fresh) + sum(1 for a in actions if a[0] == "insert")
    return actions, settings_rows, expected


def write_apply(c, actions, settings_rows):
    now = int(time.time() * 1000)
    with c:
        for kind, inbound_id, row, hosts in actions:
            data = dict(row)
            for key in ("settings", "stream_settings", "sniffing"):
                if key in data and not isinstance(data[key], str) and data[key] is not None:
                    data[key] = json.dumps(data[key], ensure_ascii=False)
            if kind == "update":
                cols = ", ".join(f'"{k}" = ?' for k in data)
                c.execute(f"update inbounds set {cols} where id = ?", [*data.values(), inbound_id])
            else:
                cols = ", ".join(f'"{k}"' for k in data)
                marks = ", ".join("?" for _ in data)
                cur = c.execute(f"insert into inbounds ({cols}) values ({marks})", list(data.values()))
                inbound_id = cur.lastrowid
            c.execute("delete from hosts where inbound_id = ?", (inbound_id,))
            host_cols = set(columns(c, "hosts"))
            for h in hosts:
                h = dict(h)
                h.update({"inbound_id": inbound_id})
                if "group_id" in host_cols:
                    h["group_id"] = group_id()
                for stamp in ("created_at", "updated_at"):
                    if stamp in host_cols:
                        h[stamp] = now
                h = {k: v for k, v in h.items() if k in host_cols}
                cols = ", ".join(f'"{k}"' for k in h)
                marks = ", ".join("?" for _ in h)
                c.execute(f"insert into hosts ({cols}) values ({marks})", list(h.values()))
        for key, value in settings_rows.items():
            if c.execute("select 1 from settings where key = ?", (key,)).fetchone():
                c.execute("update settings set value = ? where key = ?", (value, key))
            else:
                c.execute("insert into settings (key, value) values (?, ?)", (key, value))


def server_ip():
    """Адрес, на который смотрит маршрут наружу, — как у интерфейса hy2."""
    try:
        out = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"], capture_output=True,
                             text=True, timeout=5).stdout
        m = re.search(r"\bsrc (\d+\.\d+\.\d+\.\d+)", out)
        return m.group(1) if m else ""
    except Exception:
        return ""


def fresh_flag(c):
    """Флаг, который установщик поставил в названия на ЭТОМ сервере."""
    flag, _ = guess_identity([dict(r) for r in c.execute("select * from inbounds")])
    return flag


def db_copy(src, dst):
    """
    Копия базы через механизм резервного копирования SQLite, а не cp.

    3x-ui держит базу в режиме WAL: свежие записи живут в x-ui.db-wal, пока
    их не перенесут в основной файл. Замер на новом сервере 24.09.2026 —
    основной файл 270 КБ, журнал 4 МБ. Копия одного x-ui.db потеряла бы всё,
    что лежит в журнале, а откат из неё вернул бы не ту базу.
    """
    s = sqlite3.connect(src)
    d = sqlite3.connect(dst)
    try:
        s.backup(d)
    finally:
        d.close()
        s.close()
    os.chmod(dst, 0o600)


def db_restore(backup):
    """Вернуть базу из копии. Хвосты журнала от неудачного запуска удаляем,
    иначе SQLite наложил бы их поверх восстановленной базы."""
    for tail in ("-wal", "-shm"):
        try:
            os.remove(DB + tail)
        except FileNotFoundError:
            pass
    db_copy(str(backup), DB)


def systemctl(*args):
    return subprocess.run(["systemctl", *args], capture_output=True, text=True).returncode == 0


def verify(expected):
    """Проверка фактом: служба жива, xray запущен, входящих сколько нужно."""
    def alive():
        return systemctl("is-active", "--quiet", "x-ui") and \
            subprocess.run(["pgrep", "-f", "xray-linux"], capture_output=True).returncode == 0

    wait = int(os.environ.get("XUI_PROFILE_WAIT", "30"))
    for _ in range(wait):
        if alive():
            break
        time.sleep(1)
    else:
        return f"панель или xray не поднялись за {wait} секунд"
    # Второй взгляд через несколько секунд: xray с негодным конфигом успевает
    # запуститься и падает не сразу, а первая проверка поймала бы его живым.
    time.sleep(int(os.environ.get("XUI_PROFILE_SETTLE", "8")))
    if not alive():
        return "xray упал вскоре после запуска"
    c = connect(DB)
    got = c.execute("select count(*) from inbounds").fetchone()[0]
    c.close()
    if got != expected:
        return f"входящих {got}, ожидалось {expected}"
    return ""


def open_udp_ports(c):
    """awg и hy2 по UDP: панель фаервол не трогает, открываем сами."""
    if not shutil.which("ufw"):
        return
    for protocol, port in c.execute(
            "select protocol, port from inbounds where protocol in ('amneziawg','hysteria','wireguard')"):
        if port:
            subprocess.run(["ufw", "allow", f"{port}/udp"], capture_output=True)
            say(f"   фаервол: открыт {port}/udp ({protocol})")


def apply(args):
    path = Path(args.profile or PROFILE)
    if not path.is_file():
        die(f"нет шаблона: {path}")
    profile = json.loads(path.read_text(encoding="utf-8"))
    if profile.get("format") != FORMAT:
        die(f"шаблон формата {profile.get('format')}, а этот инструмент понимает {FORMAT}")

    c = connect(DB)
    # Домены — из самой панели, если не названы: адрес подписки у свежей
    # установки уже указывает на домен панели, а SNI у REALITY — на свой.
    # Так пункт меню работает и там, где стек telemt не ставился.
    if not args.domain:
        row = c.execute("select value from settings where key = 'subURI'").fetchone()
        args.domain = urlhost(row[0] if row else "")
    if not args.reality_domain:
        for (stream,) in c.execute("select stream_settings from inbounds"):
            st = loads(stream)
            names = (st.get("realitySettings") or {}).get("serverNames") if isinstance(st, dict) else None
            if names:
                args.reality_domain = names[0]
                break
    if not args.domain or not args.reality_domain:
        die("не определил домены панели по её базе — укажите --domain и --reality-domain")
    values = {"DOMAIN": args.domain, "REALITY_DOMAIN": args.reality_domain,
              "IP": args.ip or server_ip(), "FLAG": fresh_flag(c) or profile["source"].get("FLAG", ""),
              "NAME": profile["source"].get("NAME", "") if args.name is None else args.name}
    here = xui_version()
    if profile.get("xui_version") and here and profile["xui_version"] != here:
        warn(f"шаблон снят с 3x-ui {profile['xui_version']}, здесь {here} — "
             "наложение проверю фактом и откачу при сбое")

    actions, settings_rows, expected = plan_apply(c, profile, values)
    say(f"Шаблон {path.name}: снят {profile.get('made_at')} с 3x-ui {profile.get('xui_version') or '?'}")
    say(f"   флаг {values['FLAG'] or '—'}, имя {values['NAME'] or '—'}, "
        f"домены {values['DOMAIN']} / {values['REALITY_DOMAIN']}, адрес {values['IP'] or '—'}")
    for kind, _, row, hosts in actions:
        verb = "обновить" if kind == "update" else "создать "
        say(f"   {verb} «{row.get('remark')}» (хостов: {len(hosts)})")
    say(f"   настроек панели: {len(settings_rows)}; входящих станет {expected}")
    if args.dry_run:
        say("Пробный прогон: ничего не записано.")
        return

    Path(BACKUP_DIR).mkdir(parents=True, exist_ok=True)
    os.chmod(BACKUP_DIR, 0o700)
    backup = Path(BACKUP_DIR) / f"x-ui.db.before-profile-{time.strftime('%Y%m%d-%H%M%S')}"
    c.close()
    systemctl("stop", "x-ui")
    db_copy(DB, str(backup))
    try:
        c = connect(DB)
        write_apply(c, actions, settings_rows)
        c.close()
    except Exception as exc:
        db_restore(backup)
        systemctl("start", "x-ui")
        die(f"запись не удалась ({exc}) — база возвращена из копии {backup}")
    systemctl("start", "x-ui")
    problem = verify(expected)
    if problem:
        systemctl("stop", "x-ui")
        db_restore(backup)
        systemctl("start", "x-ui")
        die(f"после наложения {problem} — база возвращена из копии {backup}")
    c = connect(DB)
    open_udp_ports(c)
    c.close()
    say(f"✅ Шаблон наложен, панель работает. Копия прежней базы: {backup}")
    say("   Клиентов в шаблоне нет: добавьте их в панели и привяжите ко всем входящим.")


def show(args):
    path = Path(args.profile or PROFILE)
    if not path.is_file():
        die(f"нет шаблона: {path}")
    p = json.loads(path.read_text(encoding="utf-8"))
    say(f"Шаблон {path}: снят {p.get('made_at')} с 3x-ui {p.get('xui_version') or '?'}")
    say(f"   исходный сервер: флаг {p['source'].get('FLAG') or '—'}, имя {p['source'].get('NAME') or '—'}")
    for ib in p["inbounds"]:
        how = "поверх установщика" if ib["role"] in INSTALLER_ROLES else "создаётся по образцу"
        say(f"   • {ib.get('remark')} — {ib['role']}, {how}, хостов {len(ib.get('hosts') or [])}")
    title = p["settings"].get("subTitle")
    say(f"   настроек панели: {len(p['settings'])}" + (f"; название подписки: {title}" if title else ""))


def main():
    ap = argparse.ArgumentParser(description="Шаблон настроек 3x-ui")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("--out")
    e.add_argument("--name", help="имя сервера в названиях, если не угадалось")
    e.add_argument("--domain", help="домен панели, если не виден в subURI")
    e.add_argument("--ip")
    a = sub.add_parser("apply")
    a.add_argument("--profile")
    a.add_argument("--domain", help="домен панели; по умолчанию — из адреса подписки")
    a.add_argument("--reality-domain", help="домен REALITY; по умолчанию — из входящего reality")
    a.add_argument("--name", help="имя сервера для подписок; пусто — без имени")
    a.add_argument("--ip")
    a.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("show")
    s.add_argument("--profile")
    args = ap.parse_args()
    if args.cmd != "show" and os.geteuid() != 0 and "XUI_DB" not in os.environ:
        die("нужен root: база 3x-ui принадлежит ему")
    {"export": export, "apply": apply, "show": show}[args.cmd](args)


if __name__ == "__main__":
    main()
