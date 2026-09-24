"""
Подписка mihomo и кнопка XKeen: правка snippets/includes.conf 3x-ui-pro.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Правка ложится в чужой файл, общий для ОБОИХ доменов,
рядом с location, через которые идут подписки всех клиентов. Ошибка тут —
не пропавшая кнопка, а отвалившиеся подписки. Поэтому у каждой проверки
«добавилось» есть соседняя — «чужое осталось байт в байт».

Образец — настоящий includes.conf стенда (3x-ui-pro, 24.09.2026) с путями,
заменёнными на метки.
"""
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
ИНСТРУМЕНТ = КОРЕНЬ / "tools" / "xui-mihomo.py"

_spec = importlib.util.spec_from_file_location("xui_mihomo", ИНСТРУМЕНТ)
xm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(xm)

SUB = "/SUBPATH/"
CLASH = "/CLASHPATH/"
PORT = "46232"

ОБРАЗЕЦ = """\
    #Subscription — prefix location covers all sub-paths (assets, JS, etc.)
    location /SUBPATH/ {
        if ($hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host $host;
        proxy_pass https://127.0.0.1:46232;
    }
    location = /SUBPATH {
        if ($hack = 1) { return 404; }
        proxy_pass https://127.0.0.1:46232;
    }
    # Regex takes priority over prefix: catches subscription IDs (one-level deep)
    location ~ ^/SUBPATH/(?<clash_sub_id>[^/]+)$ {
        if ($hack = 1) { return 404; }
        if ($serve_clash_yaml = 1) { rewrite ^ /__clash_api?sub_id=$clash_sub_id last; }
        proxy_redirect off;
        proxy_set_header Host $host;
        proxy_pass https://127.0.0.1:46232;
    }
    location /assets  { proxy_pass https://127.0.0.1:46232; }

    #Subscription (json)
    location /JSONPATH/ {
        proxy_pass https://127.0.0.1:46232;
    }

    #Xray generic proxy (WS / gRPC by port+path)
    location ~ ^/(?<fwdport>\\d+)/(?<fwdpath>.*)$ {
        proxy_pass http://127.0.0.1:$fwdport$is_args$args;
    }

    location / { try_files $uri $uri/ =404; }
"""


def блок_location(text, заголовок):
    """Строки location от заголовка до закрывающей скобки его уровня."""
    lines = text.splitlines()
    i = next(n for n, l in enumerate(lines) if заголовок in l)
    глубина, out = 0, []
    for l in lines[i:]:
        out.append(l)
        глубина += l.count("{") - l.count("}")
        if глубина == 0:
            break
    return out


def test_путь_mihomo_проксируется_на_сервер_подписок():
    new = xm.render(ОБРАЗЕЦ, SUB, CLASH, PORT)
    блок = блок_location(new, "location ^~ /CLASHPATH/ {")
    assert any("proxy_pass https://127.0.0.1:46232;" in l for l in блок)
    assert any("$hack" in l for l in блок), "защита от мусорных URI как у соседей"


def test_скрипт_вставляется_в_location_страницы_а_не_в_префикс():
    """Страницу отдаёт regex-location: у regex приоритет над префиксом."""
    new = xm.render(ОБРАЗЕЦ, SUB, CLASH, PORT)
    страница = "\n".join(блок_location(new, "location ~ ^/SUBPATH/("))
    assert "sub_filter '</body>'" in страница
    assert '/SUBPATH/__vsm/xkeen.js' in страница
    assert 'proxy_set_header Accept-Encoding "";' in страница, \
        "без этого сжатый ответ sub_filter пропускает молча"
    префикс = "\n".join(блок_location(new, "location /SUBPATH/ {"))
    assert "sub_filter" not in префикс


def test_скрипт_отдаётся_точным_location():
    new = xm.render(ОБРАЗЕЦ, SUB, CLASH, PORT, js_file="/x/y.js")
    блок = "\n".join(блок_location(new, "location = /SUBPATH/__vsm/xkeen.js {"))
    assert "alias /x/y.js;" in блок
    assert "application/javascript" in блок


def test_снятие_возвращает_файл_байт_в_байт():
    new = xm.render(ОБРАЗЕЦ, SUB, CLASH, PORT)
    assert new != ОБРАЗЕЦ
    assert xm.strip(new) == ОБРАЗЕЦ


def test_повтор_не_дублирует():
    once = xm.render(ОБРАЗЕЦ, SUB, CLASH, PORT)
    twice = xm.render(once, SUB, CLASH, PORT)
    assert once == twice
    assert twice.count(xm.END) == 2


def test_смена_порта_переписывает_прежний_блок():
    old = xm.render(ОБРАЗЕЦ, SUB, CLASH, "1111")
    new = xm.render(old, SUB, CLASH, PORT)
    assert "127.0.0.1:1111" not in new


def test_чужие_location_не_тронуты():
    new = xm.render(ОБРАЗЕЦ, SUB, CLASH, PORT)
    for заголовок in ("location /SUBPATH/ {", "location = /SUBPATH {", "location /JSONPATH/ {",
                      "location ~ ^/(?<fwdport>", "location / {"):
        assert блок_location(new, заголовок) == блок_location(ОБРАЗЕЦ, заголовок)
    # И у location страницы, за вычетом нашего куска, свои строки на месте.
    было = блок_location(ОБРАЗЕЦ, "location ~ ^/SUBPATH/(")
    стало = блок_location(new, "location ~ ^/SUBPATH/(")
    assert xm.strip("\n".join(стало) + "\n") == "\n".join(было) + "\n"


def test_без_regex_location_берётся_префикс():
    образец =ОБРАЗЕЦ.replace("\n".join(блок_location(ОБРАЗЕЦ, "location ~ ^/SUBPATH/(")) + "\n", "")
    new = xm.render(образец, SUB, CLASH, PORT)
    assert "sub_filter" in "\n".join(блок_location(new, "location /SUBPATH/ {"))


@pytest.mark.parametrize("sub,clash,port,ошибка", [
    ("/SUBPATH/", "/SUBPATH/", PORT, ValueError),   # тот же путь — подписки сломались бы
    ("/SUBPATH/", "", PORT, ValueError),
    ("/SUBPATH/", CLASH, "46a", ValueError),
    ("/NOSUCH/", CLASH, PORT, LookupError),          # не конфиг 3x-ui-pro
])
def test_отказы(sub, clash, port, ошибка):
    with pytest.raises(ошибка):
        xm.render(ОБРАЗЕЦ, sub, clash, port)


def test_состояние_видит_все_три_куска():
    assert xm.status(ОБРАЗЕЦ, SUB, CLASH)["complete"] is False
    new = xm.render(ОБРАЗЕЦ, SUB, CLASH, PORT)
    st = xm.status(new, SUB, CLASH)
    assert st == {"clash_location": True, "js_location": True, "sub_filter": True, "complete": True}
    # Пропал один кусок — неполно.
    без_фильтра = "\n".join(l for l in new.splitlines() if "sub_filter '" not in l)
    assert xm.status(без_фильтра, SUB, CLASH)["complete"] is False


@pytest.mark.skipif(shutil.which("sqlite3") is None or shutil.which("bash") is None,
                    reason="нужны sqlite3 и bash")
def test_чтение_настройки_ждёт_занятую_базу(tmp_path):
    """
    Сразу после перезапуска панель держит базу. Без ожидания sqlite3 отвечал
    «database is locked», ошибка пряталась, и пустое значение читалось как
    «subURI не задан» — включение откатывалось на исправной панели.
    Поймано на стенде 24.09.2026, окно около 100 мс.
    """
    db = tmp_path / "x-ui.db"
    c = sqlite3.connect(db)
    c.execute("create table settings (id integer primary key, key text, value text)")
    c.execute("insert into settings(key, value) values ('subURI', 'https://d.example/s/')")
    c.commit()
    c.close()

    держатель = subprocess.Popen([sys.executable, "-c", (
        "import sqlite3, sys, time\n"
        "c = sqlite3.connect(sys.argv[1], isolation_level=None)\n"
        "c.execute('begin exclusive')\n"
        "print('держу', flush=True)\n"
        "time.sleep(1.5)\n"
        "c.execute('commit')\n"), str(db)], stdout=subprocess.PIPE, text=True)
    try:
        assert держатель.stdout.readline().strip() == "держу"
        r = subprocess.run(["bash", "-c", 'source "$1"; _xm_get subURI', "_",
                            str(КОРЕНЬ / "lib" / "xui_mihomo.sh")],
                           capture_output=True, text=True, env={**os.environ, "XUI_DB": str(db)})
    finally:
        держатель.wait(timeout=10)
    assert r.stdout.strip() == "https://d.example/s/"


def test_командная_строка(tmp_path):
    conf = tmp_path / "includes.conf"
    conf.write_text(ОБРАЗЕЦ, encoding="utf-8")
    run = lambda *a: subprocess.run([sys.executable, str(ИНСТРУМЕНТ), *a],
                                    capture_output=True, text=True, encoding="utf-8")
    r = run("render", "--conf", str(conf), "--sub-path", SUB, "--clash-path", CLASH, "--port", PORT)
    assert r.returncode == 0, r.stderr
    assert conf.read_text(encoding="utf-8") == ОБРАЗЕЦ, "render не пишет в файл сам"
    conf.write_text(r.stdout, encoding="utf-8")
    st = json.loads(run("status", "--conf", str(conf), "--sub-path", SUB,
                        "--clash-path", CLASH).stdout)
    assert st["complete"] is True
    r = run("render", "--conf", str(conf), "--sub-path", "/NOSUCH/", "--clash-path", CLASH,
            "--port", PORT)
    assert r.returncode == 3 and "не найден" in r.stderr
