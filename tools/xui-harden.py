#!/usr/bin/env python3
"""
Три правки nginx и панели 3x-ui-pro, которые закрывают сервер от чужих глаз.
Порядок действий (копия, nginx -t, перезагрузка, откат) — в lib/xui_harden.sh;
здесь только чтение и правка файлов, чтобы их можно было гонять тестами.

1. fwd — ПЕРЕСЫЛКА ПО НОМЕРУ ПОРТА В АДРЕСЕ. В snippets/includes.conf установщик
   ставит location ~ ^/(?<fwdport>\\d+)/… и отдаёт запрос на 127.0.0.1:<порт> —
   порт выбирает тот, кто прислал запрос. Замер на главном 10.10.2026 снаружи,
   без пароля: /9444/ отдал страницу telemt-panel в обход её секретного пути,
   /8090/ — страницу хаба beszel, /21126/ — службу диагностики. Правилом
   пользуются только соединения WS и gRPC, у которых путь начинается с их же
   порта. Оставляем ровно их порты.

2. sni — СОЕДИНЕНИЯ БЕЗ НАШЕГО ИМЕНИ. Карта stream отправляет всё, чего не
   знает, в REALITY (default xray), а тот — на сайт-заглушку. Замер 10.10:
   без SNI и с чужим SNI сервер отдавал сертификат adkrw.egevad.se, TLS 1.3 и
   h2 — ровно то, что ищет RealiTLScanner, чтобы найти домен и маскироваться им
   же. Теперь неизвестное имя уходит на пустой сервер nginx с
   ssl_reject_handshake: рукопожатие обрывается, сертификата не видно.

3. listen — ПАНЕЛЬ НА ПЕТЛЕ: webListen и subListen = 127.0.0.1. nginx и так
   ходит к ней через 127.0.0.1, а наружу её закрывал только фаервол.
"""

import argparse
import json
import re
import sqlite3
import sys

REJECT_UPSTREAM = "vsm_reject"

# location ~ ^/(?<fwdport>ЧТО-ТО)/(?<fwdpath>.*)$ {
FWD_RE = re.compile(r"(location\s+~\s+\^/\(\?<fwdport>)(.*?)(\)/\(\?<fwdpath>)")
# Ни один порт не разрешён: группа, которая не совпадает ни с чем.
FWD_NONE = "(?!)"


# ------------------------------------------------------------------- fwd
def fwd_wanted(db: str) -> list:
    """Порты соединений, которым нужна пересылка: WS, HTTPUpgrade и gRPC, чей
    путь начинается с их же порта. Нечитаемую строку пропускаем: в базе
    встречается stream_settings, на котором json_extract падает (10.10.2026)."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    try:
        rows = con.execute("select port, stream_settings from inbounds where enable = 1").fetchall()
    finally:
        con.close()
    out = set()
    for port, raw in rows:
        try:
            ss = json.loads(raw or "{}")
            port = int(port)
        except (TypeError, ValueError):
            continue
        if not isinstance(ss, dict) or port <= 0:
            continue
        net = ss.get("network")
        path = ""
        if net == "ws":
            path = (ss.get("wsSettings") or {}).get("path") or ""
        elif net == "httpupgrade":
            path = (ss.get("httpupgradeSettings") or {}).get("path") or ""
        elif net == "grpc":
            path = (ss.get("grpcSettings") or {}).get("serviceName") or ""
        if str(path).lstrip("/").startswith(f"{port}/"):
            out.add(port)
    return sorted(out)


def fwd_state(text: str) -> str:
    """'нет правила' | 'любой порт' | 'никакой' | 'только: 1 2'."""
    m = FWD_RE.search(text)
    if not m:
        return "нет правила"
    body = m.group(2)
    if body in (r"\d+", r"[0-9]+"):
        return "любой порт"
    if body == FWD_NONE:
        return "никакой"
    parts = body.split("|")
    if not all(p.isdigit() for p in parts):
        return f"не разобрать: {body}"
    return "только: " + " ".join(str(p) for p in sorted(int(p) for p in parts))


def fwd_want_label(ports: list) -> str:
    return "только: " + " ".join(str(p) for p in ports) if ports else "никакой"


def fwd_apply(text: str, ports: list) -> str:
    body = "|".join(str(p) for p in sorted(ports)) if ports else FWD_NONE
    new, n = FWD_RE.subn(lambda m: m.group(1) + body + m.group(3), text, count=1)
    if not n:
        raise ValueError("правило пересылки по порту не найдено")
    return new


# ------------------------------------------------------------------- sni
_MAP_RE = re.compile(r"map\s+\$ssl_preread_server_name\s+\$\w+\s*\{(.*?)\}", re.S)
_DEFAULT_RE = re.compile(r"(^\s*default\s+)(\S+?)(\s*;)", re.M)


def sni_state(text: str) -> str:
    """'обрыв' | 'в <имя>' | 'нет карты'."""
    m = _MAP_RE.search(text)
    if not m:
        return "нет карты"
    d = _DEFAULT_RE.search(m.group(1))
    target = d.group(2) if d else "(нет default)"
    if target == REJECT_UPSTREAM:
        has_up = re.search(r"upstream\s+" + REJECT_UPSTREAM + r"\s*\{", text)
        return "обрыв" if has_up else "обрыв без upstream"
    return f"в {target}"


def sni_apply(text: str, port: int) -> str:
    m = _MAP_RE.search(text)
    if not m:
        raise ValueError("карта $ssl_preread_server_name не найдена")
    body = m.group(1)
    if _DEFAULT_RE.search(body):
        body = _DEFAULT_RE.sub(lambda d: d.group(1) + REJECT_UPSTREAM + d.group(3), body, count=1)
    else:
        body = body.rstrip() + f"\n    default              {REJECT_UPSTREAM};\n"
    text = text[:m.start(1)] + body + text[m.end(1):]
    up = f"upstream {REJECT_UPSTREAM} {{ server 127.0.0.1:{port}; }}"
    up_re = re.compile(r"upstream\s+" + REJECT_UPSTREAM + r"\s*\{[^}]*\}")
    if up_re.search(text):
        text = up_re.sub(up, text, count=1)
    else:
        # Сразу после карты: upstream должен быть объявлен в том же stream{}.
        end = _MAP_RE.search(text).end()
        text = text[:end] + "\n\n# VSM: имена, которых нет в карте, — обрыв рукопожатия.\n" + up + text[end:]
    return text


def sni_reject_conf(port: int) -> str:
    return (
        "# VSM (lib/xui_harden.sh): сюда stream отправляет соединения с именем,\n"
        "# которого нет в его карте, и без имени вовсе. Рукопожатие обрывается,\n"
        "# сертификат не показывается — сканер не узнаёт наш домен по адресу.\n"
        "server {\n"
        f"    listen 127.0.0.1:{port} ssl proxy_protocol;\n"
        "    ssl_reject_handshake on;\n"
        "}\n"
    )


# ---------------------------------------------------------------- listen
def listen_state(db: str) -> str:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    try:
        got = dict(con.execute(
            "select key, value from settings where key in ('webListen','subListen')").fetchall())
    finally:
        con.close()
    return f"панель {got.get('webListen') or 'все'} · подписка {got.get('subListen') or 'все'}"


LISTEN_WANT = "панель 127.0.0.1 · подписка 127.0.0.1"


# ------------------------------------------------------------------ CLI
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["fwd-wanted", "fwd-state", "fwd-want", "fwd-apply",
                                    "sni-state", "sni-apply", "sni-conf",
                                    "listen-state", "listen-want"])
    ap.add_argument("--db", default="/etc/x-ui/x-ui.db")
    ap.add_argument("--file")
    ap.add_argument("--port", type=int, default=7449)
    a = ap.parse_args()
    try:
        if a.cmd == "fwd-wanted":
            print(" ".join(str(p) for p in fwd_wanted(a.db)))
        elif a.cmd == "fwd-want":
            print(fwd_want_label(fwd_wanted(a.db)))
        elif a.cmd == "fwd-state":
            print(fwd_state(open(a.file, encoding="utf-8").read()))
        elif a.cmd == "fwd-apply":
            sys.stdout.write(fwd_apply(open(a.file, encoding="utf-8").read(), fwd_wanted(a.db)))
        elif a.cmd == "sni-state":
            print(sni_state(open(a.file, encoding="utf-8").read()))
        elif a.cmd == "sni-apply":
            sys.stdout.write(sni_apply(open(a.file, encoding="utf-8").read(), a.port))
        elif a.cmd == "sni-conf":
            sys.stdout.write(sni_reject_conf(a.port))
        elif a.cmd == "listen-state":
            print(listen_state(a.db))
        elif a.cmd == "listen-want":
            print(LISTEN_WANT)
    except (OSError, ValueError, sqlite3.Error) as exc:
        print(f"xui-harden: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
