#!/usr/bin/env python3
"""
ПОДПИСКА mihomo И КНОПКА XKeen: правка конфига nginx 3x-ui-pro.

    python3 tools/xui-mihomo.py render --conf ФАЙЛ --sub-path П --clash-path П
                                       --port ПОРТ [--js-file ФАЙЛ]
    python3 tools/xui-mihomo.py strip  --conf ФАЙЛ
    python3 tools/xui-mihomo.py status --conf ФАЙЛ --sub-path П --clash-path П

render и strip печатают НОВЫЙ текст конфига в stdout и файл не трогают:
запись, копия, nginx -t и откат — дело вызывающего (lib/xui_mihomo.sh).
Так правку можно проверить на образце без nginx.

ЗАЧЕМ. В 3x-ui 3.8 есть своя подписка в формате mihomo (subClashEnable): все
подключения клиента плюс AmneziaWG с version: 3 и полями 3.1. Роутеру с XKeen
она заменяет ручной блок proxies с ключами AWG — после переустановки сервера
новые ключи он заберёт сам. Но установщик 3x-ui-pro пускает через nginx
только обычную подписку и JSON, путь mihomo отдаёт 404.

ЧТО ДОБАВЛЯЕТСЯ. Два куска между метками VSM:

  1. рядом с location подписки — location пути mihomo (прокси на сервер
     подписок, как у соседей) и точный location скрипта кнопки;
  2. внутри location, который отдаёт страницу подписки, — sub_filter,
     вставляющий <script> перед </body>. Accept-Encoding снимается: сжатый
     ответ sub_filter пропускает молча, и кнопка бы просто не появилась.

sub_filter действует только на text/html, поэтому сами подписки (text/plain,
YAML) он не трогает.

ЧУЖОЙ ФАЙЛ. snippets/includes.conf пишет установщик 3x-ui-pro, его патч может
переписать файл целиком — вместе с нашими кусками. Пропажу видит позиция
реестра xui_mihomo, возвращает пункт меню X-UI «Роутер (XKeen)».
"""

import argparse
import json
import re
import sys

BEGIN = "# >>> VSM mihomo — не редактируй вручную"
END = "# <<< VSM mihomo"
JS_FILE = "/var/www/vsm-sub/xkeen.js"
JS_NAME = "__vsm/xkeen.js"


def norm(path):
    """/abc/ -> abc. Панель хранит пути со слэшами по краям, но не всегда."""
    return (path or "").strip().strip("/")


def strip(text):
    """Убрать все куски между метками VSM. Остальное — байт в байт."""
    out, skip = [], False
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s.startswith(BEGIN.split(" — ")[0]):
            skip = True
            continue
        if skip and s.startswith(END):
            skip = False
            continue
        if not skip:
            out.append(line)
    return "".join(out)


def find_page_location(lines, sub):
    """
    Номер строки location, который отдаёт страницу подписки /<sub>/<id>.

    У 3x-ui-pro это regex-location (он же разводит клиентов Clash на свой
    генератор) — у regex приоритет над префиксом, значит страница идёт через
    него. На раскладке без него страница идёт через префикс /<sub>/.
    """
    esc = re.escape(sub)
    rx = re.compile(r"^\s*location\s+~\*?\s+\^?/" + esc + r"/\(")
    for i, line in enumerate(lines):
        if rx.search(line) and line.rstrip().endswith("{"):
            return i
    pre = re.compile(r"^\s*location\s+/" + esc + r"/\s*\{")
    for i, line in enumerate(lines):
        if pre.search(line):
            return i
    return None


def render(text, sub, clash, port, js_file=JS_FILE):
    sub, clash = norm(sub), norm(clash)
    if not sub or not clash:
        raise ValueError("пустой путь подписки или mihomo")
    if sub == clash:
        raise ValueError("путь mihomo совпадает с путём обычной подписки")
    if not str(port).isdigit():
        raise ValueError("порт сервера подписок не число: %r" % port)

    lines = strip(text).splitlines(keepends=True)
    at = find_page_location(lines, sub)
    if at is None:
        raise LookupError("не найден location подписки /%s/ — не конфиг 3x-ui-pro?" % sub)

    indent = re.match(r"^(\s*)", lines[at]).group(1)
    inner = indent + "    "
    js_url = "/%s/%s" % (sub, JS_NAME)

    outer = [
        indent + BEGIN + "\n",
        # ^~ — чтобы regex-location xray ^/(\d+)/ не перехватил путь,
        # начинающийся с цифр: у regex приоритет над обычным префиксом.
        indent + "location ^~ /%s/ {\n" % clash,
        inner + "if ($hack = 1) { return 404; }\n",
        inner + "proxy_redirect off;\n",
        inner + "proxy_set_header Host $host;\n",
        inner + "proxy_set_header X-Real-IP $remote_addr;\n",
        inner + "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n",
        inner + "proxy_pass https://127.0.0.1:%s;\n" % port,
        indent + "}\n",
        indent + "location = %s {\n" % js_url,
        inner + "alias %s;\n" % js_file,
        inner + "default_type application/javascript;\n",
        inner + 'add_header Cache-Control "no-cache";\n',
        indent + "}\n",
        indent + END + "\n",
    ]
    page = [
        inner + BEGIN + "\n",
        inner + 'proxy_set_header Accept-Encoding "";\n',
        inner + "sub_filter '</body>' '<script src=\"%s\" defer></script></body>';\n" % js_url,
        inner + "sub_filter_once on;\n",
        inner + END + "\n",
    ]
    return "".join(lines[:at] + outer + [lines[at]] + page + lines[at + 1:])


def status(text, sub, clash):
    sub, clash = norm(sub), norm(clash)
    lines = text.splitlines()
    has_clash = any(re.search(r"^\s*location\s+(\^~\s+)?/" + re.escape(clash) + r"/\s*\{", l) for l in lines) \
        if clash else False
    has_js = any(("location = /%s/%s" % (sub, JS_NAME)) in l for l in lines)
    has_filter = any("sub_filter" in l and JS_NAME in l for l in lines)
    return {"clash_location": has_clash, "js_location": has_js, "sub_filter": has_filter,
            "complete": has_clash and has_js and has_filter}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Подписка mihomo и кнопка XKeen в nginx 3x-ui-pro")
    sp = ap.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("render")
    r.add_argument("--conf", required=True)
    r.add_argument("--sub-path", required=True)
    r.add_argument("--clash-path", required=True)
    r.add_argument("--port", required=True)
    r.add_argument("--js-file", default=JS_FILE)
    s = sp.add_parser("strip")
    s.add_argument("--conf", required=True)
    st = sp.add_parser("status")
    st.add_argument("--conf", required=True)
    st.add_argument("--sub-path", required=True)
    st.add_argument("--clash-path", default="")
    a = ap.parse_args(argv)

    with open(a.conf, encoding="utf-8") as f:
        text = f.read()

    if a.cmd == "strip":
        sys.stdout.write(strip(text))
        return 0
    if a.cmd == "status":
        print(json.dumps(status(text, a.sub_path, a.clash_path)))
        return 0
    try:
        sys.stdout.write(render(text, a.sub_path, a.clash_path, a.port, a.js_file))
    except (ValueError, LookupError) as e:
        print(str(e), file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
