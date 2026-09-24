"""
Шаблон настроек 3x-ui: снять с одного сервера, наложить на свежую установку.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Инструмент пишет прямо в базу чужой панели от root.
Ошибка здесь — не косметика: перенесённый чужой путь ws разрывает связь с
nginx, перенесённый ключ REALITY выдаёт один сервер за другой, а стёртый ключ
awg оставляет входящий, к которому нечем подключиться. Поэтому у каждой
проверки «перенеслось» есть соседняя — «своё от установщика осталось своим».

Базы строятся из той же схемы, что у 3x-ui 3.8.5 на серверах (столбцы,
которые читает инструмент), и заполняются так, как их заполняют установщик
3x-ui-pro и владелец. Настоящая база сервера в тесты не попадает: там ключи.

ВСЕ СИСТЕМНЫЕ КОМАНДЫ — ЗАГЛУШКИ. Наложение останавливает и запускает x-ui,
ищет процесс xray, открывает порты в ufw. Тесты гоняются на стенде, где всё
это настоящее; без заглушек прогон перезапускал бы живую панель стенда.
"""
import base64
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
ИНСТРУМЕНТ = КОРЕНЬ / "tools" / "xui-profile.py"

СХЕМА = """
CREATE TABLE inbounds (id integer PRIMARY KEY AUTOINCREMENT, user_id integer, up integer,
  down integer, total integer, remark text, sub_sort_index integer DEFAULT 1, enable numeric,
  expiry_time integer, traffic_reset text DEFAULT "never", traffic_reset_day integer DEFAULT 1,
  last_traffic_reset_time integer DEFAULT 0, listen text, port integer, protocol text,
  settings text, stream_settings text, tag text, sniffing text, node_id integer,
  share_addr_strategy text DEFAULT "node", share_addr text, disable_flow numeric DEFAULT false,
  origin_node_guid text, CONSTRAINT uni_inbounds_tag UNIQUE (tag));
CREATE TABLE hosts (id integer PRIMARY KEY AUTOINCREMENT, group_id text, inbound_id integer NOT NULL,
  sort_order integer DEFAULT 0, remark text, is_disabled numeric DEFAULT false,
  is_hidden numeric DEFAULT false, address text, port integer DEFAULT 0,
  security text DEFAULT "same", sni text, alpn text, fingerprint text,
  created_at integer, updated_at integer);
CREATE TABLE settings (id integer PRIMARY KEY AUTOINCREMENT, key text, value text);
"""

ДОМЕН_А, РЕАЛИТИ_А, IP_А = "adk.gnilron.se", "adkrw.gnilron.se", "179.254.109.140"
ДОМЕН_Б, РЕАЛИТИ_Б, IP_Б = "panel.example.org", "real.example.org", "203.0.113.7"


def поток_reality(домен, ключ):
    return {"network": "tcp", "security": "reality", "tcpSettings": {"acceptProxyProtocol": True},
            "realitySettings": {"target": "127.0.0.1:9443", "serverNames": [домен],
                                "privateKey": ключ, "shortIds": ["aa", "bb"],
                                "minClientVer": "", "settings": {"publicKey": ключ + "pub",
                                                                 "fingerprint": "firefox"}}}


def вставить(c, remark, port, protocol, settings, stream, tag, listen="", enable=1, sort=1,
             sniffing=None):
    cur = c.execute(
        "insert into inbounds (user_id, up, down, total, remark, sub_sort_index, enable, "
        "expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) "
        "values (1, 0, 0, 0, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)",
        (remark, sort, enable, listen, port, protocol, json.dumps(settings),
         None if stream is None else json.dumps(stream), tag,
         json.dumps(sniffing or {"enabled": False})))
    return cur.lastrowid


def свежая_установка(путь, домен, реалити, ws_port, trojan_port, флаг="🌐"):
    """Как после установщика 3x-ui-pro: четыре входящих, четыре хоста, клиентов нет."""
    c = sqlite3.connect(путь)
    c.executescript(СХЕМА)
    r = вставить(c, f"{флаг} reality", 8443, "vless", {"clients": [], "decryption": "none"},
                 поток_reality(реалити, "СВОЙКЛЮЧ"), "in-8443-tcp")
    w = вставить(c, f"{флаг} ws", ws_port, "vless", {"clients": [], "decryption": "none"},
                 {"network": "ws", "security": "none",
                  "wsSettings": {"path": f"/{ws_port}/свойпуть", "host": домен}}, f"in-{ws_port}-tcp")
    x = вставить(c, f"{флаг} xhttp", 0, "vless", {"clients": [], "decryption": "none"},
                 {"network": "xhttp", "security": "none",
                  "xhttpSettings": {"path": "/свойxhttp", "host": домен, "mode": "packet-up"}},
                 "in-0-tcp", listen="/dev/shm/uds2023.sock,0666", enable=0)
    t = вставить(c, f"{флаг} trojan-grpc", trojan_port, "trojan", {"clients": []},
                 {"network": "grpc", "security": "none",
                  "grpcSettings": {"serviceName": f"/{trojan_port}/свойgrpc", "authority": домен}},
                 f"in-{trojan_port}-tcp")
    for ib, remark in ((r, "reality"), (w, "ws"), (x, "xhttp"), (t, "trojan")):
        c.execute("insert into hosts (group_id, inbound_id, remark, address, port, security, "
                  "fingerprint, alpn) values ('g', ?, ?, ?, 443, 'tls', 'firefox', '[]')",
                  (ib, remark, домен))
    for k, v in (("subPath", "/свойsub/"), ("subURI", f"https://{домен}/свойsub/"),
                 ("subPort", "11111"), ("webBasePath", "/свояпанель/"), ("subTitle", ""),
                 ("subCertFile", f"/root/cert/{домен}/fullchain.pem")):
        c.execute("insert into settings (key, value) values (?, ?)", (k, v))
    c.commit()
    c.close()


def сервер_владельца(путь):
    """Сервер А после правок владельца: названия, подписка, xhttp включён, hy2 и awg."""
    свежая_установка(путь, ДОМЕН_А, РЕАЛИТИ_А, 24101, 33543, флаг="🇸🇪")
    c = sqlite3.connect(путь)
    for suffix, sort in (("reality", 2), ("ws", 4), ("xhttp", 1), ("trojan-grpc", 5)):
        c.execute("update inbounds set remark = ?, sub_sort_index = ? where remark = ?",
                  (f"🇸🇪 My1Cent {suffix}", sort, f"🇸🇪 {suffix}"))
    c.execute("update inbounds set enable = 1, sniffing = ? where port = 0",
              (json.dumps({"enabled": True, "destOverride": ["http", "tls"]}),))
    st = json.loads(c.execute("select stream_settings from inbounds where port = 8443").fetchone()[0])
    st["realitySettings"]["minClientVer"] = "1.8.1"
    c.execute("update inbounds set stream_settings = ?, settings = ? where port = 8443",
              (json.dumps(st), json.dumps({"clients": [{"id": "клиент-uuid"}], "decryption": "none"})))
    hy2 = вставить(c, "🇸🇪 My1Cent hy2", 443, "hysteria", {"clients": [{"auth": "секрет"}], "version": 2},
                   {"network": "hysteria", "security": "tls",
                    "tlsSettings": {"serverName": ДОМЕН_А, "certificates": [
                        {"certificateFile": f"/root/cert/{ДОМЕН_А}/fullchain.pem",
                         "keyFile": f"/root/cert/{ДОМЕН_А}/privkey.pem"}]},
                    "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "СТАРЫЙПАРОЛЬ"}}]}},
                   "in-443-udp", listen=IP_А, sort=6)
    вставить(c, "🇸🇪 My1Cent awg", 26680, "amneziawg",
             {"clients": [], "server": {"privateKey": "СТАРЫЙПРИВ", "publicKey": "СТАРЫЙПУБ",
                                        "headerProtectionKey": "СТАРЫЙHPK", "jc": 3, "s1": 111,
                                        "h1": "52956019", "subnetIp": "10.8.1.0"}},
             None, "in-26680-udp", sort=3)
    c.execute("insert into hosts (group_id, inbound_id, remark, address, port, security) "
              "values ('g', ?, 'hy2', ?, 443, 'same')", (hy2, ДОМЕН_А))
    for k, v in (("subTitle", "🇸🇪 adkrw My1Cent"), ("subSupportUrl", "https://t.me/adkrw"),
                 ("subAnnounce", "Контакты: https://t.me/adkrw"), ("subUpdates", "1"),
                 ("tgBotToken", "ТОКЕН-НЕ-ПЕРЕНОСИТЬ"), ("remarkModel", "-ieo")):
        if c.execute("select 1 from settings where key = ?", (k,)).fetchone():
            c.execute("update settings set value = ? where key = ?", (v, k))
        else:
            c.execute("insert into settings (key, value) values (?, ?)", (k, v))
    c.commit()
    c.close()


@pytest.fixture
def заглушки(tmp_path):
    """Каталог поддельных системных команд впереди PATH и журнал их вызовов."""
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    журнал = tmp_path / "вызовы.log"
    for имя in ("systemctl", "pgrep", "ufw", "ss", "ip"):
        f = bin_ / имя
        f.write_text(f'#!/bin/sh\necho "{имя} $*" >> "{журнал.as_posix()}"\nexit 0\n')
        f.chmod(0o755)
    return bin_, журнал


def запустить(tmp_path, заглушки, *args, db):
    bin_, _ = заглушки
    env = dict(os.environ)
    env.update({"PATH": f"{bin_.as_posix()}:{env.get('PATH', '')}", "XUI_DB": str(db),
                "XUI_BIN": str(tmp_path / "нет-x-ui"),
                "XUI_PROFILE_WAIT": "2", "XUI_PROFILE_SETTLE": "0",
                "XUI_PROFILE_BACKUP_DIR": str(tmp_path / "копии")})
    return subprocess.run([sys.executable, str(ИНСТРУМЕНТ), *args], capture_output=True,
                          text=True, encoding="utf-8", env=env)


pytestmark = pytest.mark.skipif(os.name == "nt", reason="нужны POSIX-заглушки")


@pytest.fixture
def шаблон(tmp_path, заглушки):
    db = tmp_path / "a.db"
    сервер_владельца(db)
    out = tmp_path / "профиль.json"
    ответ = запустить(tmp_path, заглушки, "export", "--out", str(out), db=db)
    assert ответ.returncode == 0, ответ.stderr
    return out


@pytest.fixture
def наложенный(tmp_path, заглушки, шаблон):
    db = tmp_path / "b.db"
    свежая_установка(db, ДОМЕН_Б, РЕАЛИТИ_Б, 40001, 40002, флаг="🇩🇪")
    ответ = запустить(tmp_path, заглушки, "apply", "--profile", str(шаблон), "--domain", ДОМЕН_Б,
                      "--reality-domain", РЕАЛИТИ_Б, "--name", "Hetzner", "--ip", IP_Б, db=db)
    assert ответ.returncode == 0, ответ.stdout + ответ.stderr
    return db


def входящие(db):
    c = sqlite3.connect(db)
    c.row_factory = sqlite3.Row
    rows = {r["remark"]: dict(r) for r in c.execute("select * from inbounds")}
    c.close()
    return rows


def настройка(db, key):
    c = sqlite3.connect(db)
    row = c.execute("select value from settings where key = ?", (key,)).fetchone()
    c.close()
    return row[0] if row else None


# --- снятие -----------------------------------------------------------------

def test_в_шаблоне_нет_адресов_сервера(шаблон):
    текст = шаблон.read_text(encoding="utf-8")
    for адрес in (ДОМЕН_А, РЕАЛИТИ_А, IP_А):
        assert адрес not in текст, адрес
    assert "{DOMAIN}" in текст and "{IP}" in текст


def test_в_шаблоне_нет_секретов(шаблон):
    текст = шаблон.read_text(encoding="utf-8")
    for секрет in ("СВОЙКЛЮЧ", "клиент-uuid", "СТАРЫЙПАРОЛЬ", "СТАРЫЙПРИВ", "СТАРЫЙHPK",
                   "ТОКЕН-НЕ-ПЕРЕНОСИТЬ", "секрет"):
        assert секрет not in текст, секрет


def test_имя_и_флаг_угаданы_и_стали_метками(шаблон):
    p = json.loads(шаблон.read_text(encoding="utf-8"))
    assert p["source"] == {"FLAG": "🇸🇪", "NAME": "My1Cent"}
    assert p["settings"]["subTitle"] == "{FLAG} adkrw {NAME}"
    remarks = [i["remark"] for i in p["inbounds"]]
    assert "{FLAG} {NAME} reality" in remarks


def test_привязанные_к_установке_настройки_не_снимаются(шаблон):
    p = json.loads(шаблон.read_text(encoding="utf-8"))
    for key in ("subPath", "subURI", "subPort", "webBasePath", "subCertFile", "tgBotToken"):
        assert key not in p["settings"], key


# --- наложение --------------------------------------------------------------

def test_названия_стали_своими_на_новом_сервере(наложенный):
    names = set(входящие(наложенный))
    # Правило VSM: входящий — «флаг тип», сервис — только в названии подписки.
    assert {"🇩🇪 reality", "🇩🇪 ws", "🇩🇪 xhttp",
            "🇩🇪 trojan-grpc", "🇩🇪 hy2", "🇩🇪 awg"} == names
    assert настройка(наложенный, "subTitle") == "🇩🇪 Hetzner {{EMAIL}}"
    assert настройка(наложенный, "subSupportUrl") == "https://t.me/adkrw"


def test_порты_и_пути_остались_от_установщика(наложенный):
    """Обратная сторона: чужой путь ws разорвал бы связь с nginx."""
    ib = входящие(наложенный)
    ws = json.loads(ib["🇩🇪 ws"]["stream_settings"])
    assert ib["🇩🇪 ws"]["port"] == 40001
    assert ws["wsSettings"] == {"path": "/40001/свойпуть", "host": ДОМЕН_Б}
    grpc = json.loads(ib["🇩🇪 trojan-grpc"]["stream_settings"])["grpcSettings"]
    assert grpc["serviceName"] == "/40002/свойgrpc" and grpc["authority"] == ДОМЕН_Б
    assert настройка(наложенный, "subPath") == "/свойsub/"
    assert настройка(наложенный, "webBasePath") == "/свояпанель/"


def test_ключи_reality_свои_а_вкус_перенесён(наложенный):
    rs = json.loads(входящие(наложенный)["🇩🇪 reality"]["stream_settings"])["realitySettings"]
    assert rs["privateKey"] == "СВОЙКЛЮЧ" and rs["settings"]["publicKey"] == "СВОЙКЛЮЧpub"
    assert rs["serverNames"] == [РЕАЛИТИ_Б]
    assert rs["minClientVer"] == "1.8.1", "правка владельца потерялась"


def test_xhttp_включён_как_у_владельца(наложенный):
    x = входящие(наложенный)["🇩🇪 xhttp"]
    assert x["enable"] == 1
    assert json.loads(x["sniffing"])["enabled"] is True
    assert x["listen"] == "/dev/shm/uds2023.sock,0666"


def test_hy2_создан_с_новым_доменом_адресом_и_паролем(наложенный):
    hy = входящие(наложенный)["🇩🇪 hy2"]
    st = json.loads(hy["stream_settings"])
    assert hy["listen"] == IP_Б and hy["port"] == 443
    assert st["tlsSettings"]["certificates"][0]["certificateFile"] == f"/root/cert/{ДОМЕН_Б}/fullchain.pem"
    пароль = st["finalmask"]["udp"][0]["settings"]["password"]
    assert пароль and пароль != "СТАРЫЙПАРОЛЬ" and len(пароль) == 16
    assert json.loads(hy["settings"])["clients"] == []


def test_awg_создан_с_новыми_ключами_и_параметрами_владельца(наложенный):
    awg = входящие(наложенный)["🇩🇪 awg"]
    server = json.loads(awg["settings"])["server"]
    assert server["jc"] == 3 and server["h1"] == "52956019"
    assert server["privateKey"] != "СТАРЫЙПРИВ" and len(base64.b64decode(server["privateKey"])) == 32
    assert len(base64.b64decode(server["headerProtectionKey"])) == 32
    assert 20000 <= awg["port"] < 60000 and awg["tag"] == f"in-{awg['port']}-udp"


def test_хосты_перенесены_к_своим_входящим(наложенный):
    c = sqlite3.connect(наложенный)
    rows = c.execute("select i.remark, h.address from hosts h join inbounds i on i.id = h.inbound_id").fetchall()
    c.close()
    assert ("🇩🇪 hy2", ДОМЕН_Б) in rows
    assert all(addr == ДОМЕН_Б for _, addr in rows), rows
    assert len(rows) == 5


def test_повторное_наложение_не_стирает_ключи_awg(tmp_path, заглушки, шаблон, наложенный):
    """Секретов в шаблоне нет — второй прогон обязан взять их из базы."""
    до = json.loads(входящие(наложенный)["🇩🇪 awg"]["settings"])["server"]["privateKey"]
    ответ = запустить(tmp_path, заглушки, "apply", "--profile", str(шаблон), "--domain", ДОМЕН_Б,
                      "--reality-domain", РЕАЛИТИ_Б, "--name", "Hetzner", "--ip", IP_Б,
                      db=наложенный)
    assert ответ.returncode == 0, ответ.stderr
    ib = входящие(наложенный)
    assert len(ib) == 6, "второй прогон размножил входящие"
    assert json.loads(ib["🇩🇪 awg"]["settings"])["server"]["privateKey"] == до


def test_пустое_имя_без_двойных_пробелов(tmp_path, заглушки, шаблон):
    db = tmp_path / "c.db"
    свежая_установка(db, ДОМЕН_Б, РЕАЛИТИ_Б, 40001, 40002, флаг="🇩🇪")
    ответ = запустить(tmp_path, заглушки, "apply", "--profile", str(шаблон), "--domain", ДОМЕН_Б,
                      "--reality-domain", РЕАЛИТИ_Б, "--name", "", "--ip", IP_Б, db=db)
    assert ответ.returncode == 0, ответ.stderr
    assert "🇩🇪 reality" in входящие(db)
    assert настройка(db, "subTitle") == "🇩🇪 {{EMAIL}}"


def test_сервис_переживает_перенос_по_новому_правилу(tmp_path, заглушки, наложенный):
    """
    По новому правилу имени сервиса во входящих нет («🇩🇪 reality»), оно живёт
    только в названии подписки. Снятие обязано найти его там — иначе шаблон
    с такого сервера понесёт «Hetzner» как текст и на следующем сервере
    подписка назовётся чужим сервисом.
    """
    out = tmp_path / "профиль-б.json"
    ответ = запустить(tmp_path, заглушки, "export", "--out", str(out), db=наложенный)
    assert ответ.returncode == 0, ответ.stderr
    p = json.loads(out.read_text(encoding="utf-8"))
    assert p["source"] == {"FLAG": "🇩🇪", "NAME": "Hetzner"}
    assert "Hetzner" not in out.read_text(encoding="utf-8").replace('"NAME": "Hetzner"', "")

    db = tmp_path / "d.db"
    свежая_установка(db, ДОМЕН_А, РЕАЛИТИ_А, 40011, 40012, флаг="🇫🇮")
    ответ = запустить(tmp_path, заглушки, "apply", "--profile", str(out), "--domain", ДОМЕН_А,
                      "--reality-domain", РЕАЛИТИ_А, "--name", "Aeza", "--ip", IP_А, db=db)
    assert ответ.returncode == 0, ответ.stdout + ответ.stderr
    assert "🇫🇮 xhttp" in входящие(db)
    assert настройка(db, "subTitle") == "🇫🇮 Aeza {{EMAIL}}"


def test_домены_берутся_из_базы_панели(tmp_path, заглушки, шаблон):
    """Пункт меню не знает доменов стека — берёт их из адреса подписки и REALITY."""
    db = tmp_path / "f.db"
    свежая_установка(db, ДОМЕН_Б, РЕАЛИТИ_Б, 40001, 40002, флаг="🇩🇪")
    ответ = запустить(tmp_path, заглушки, "apply", "--profile", str(шаблон), "--name", "N",
                      "--ip", IP_Б, db=db)
    assert ответ.returncode == 0, ответ.stderr
    hy = json.loads(входящие(db)["🇩🇪 hy2"]["stream_settings"])
    assert hy["tlsSettings"]["serverName"] == ДОМЕН_Б
    assert РЕАЛИТИ_Б in ответ.stdout


def test_пробный_прогон_ничего_не_пишет(tmp_path, заглушки, шаблон):
    db = tmp_path / "d.db"
    свежая_установка(db, ДОМЕН_Б, РЕАЛИТИ_Б, 40001, 40002)
    до = db.read_bytes()
    ответ = запустить(tmp_path, заглушки, "apply", "--profile", str(шаблон), "--domain", ДОМЕН_Б,
                      "--reality-domain", РЕАЛИТИ_Б, "--dry-run", db=db)
    assert ответ.returncode == 0, ответ.stderr
    assert db.read_bytes() == до


def test_копия_снята_и_порты_udp_открыты(tmp_path, заглушки, наложенный):
    _, журнал = заглушки
    копии = list((tmp_path / "копии").iterdir())
    assert копии and копии[0].name.startswith("x-ui.db.before-profile-")
    вызовы = журнал.read_text(encoding="utf-8")
    assert "systemctl stop x-ui" in вызовы and "systemctl start x-ui" in вызовы
    assert "ufw allow 443/udp" in вызовы


def test_при_сбое_проверки_база_возвращается(tmp_path, заглушки, шаблон):
    """xray не поднялся — база обязана вернуться к виду до наложения."""
    bin_, _ = заглушки
    (bin_ / "pgrep").write_text("#!/bin/sh\nexit 1\n")
    db = tmp_path / "e.db"
    свежая_установка(db, ДОМЕН_Б, РЕАЛИТИ_Б, 40001, 40002, флаг="🇩🇪")
    ответ = запустить(tmp_path, заглушки, "apply", "--profile", str(шаблон), "--domain", ДОМЕН_Б,
                      "--reality-domain", РЕАЛИТИ_Б, "--name", "X", "--ip", IP_Б, db=db)
    assert ответ.returncode != 0
    assert "возвращена из копии" in ответ.stderr
    assert set(входящие(db)) == {"🇩🇪 reality", "🇩🇪 ws", "🇩🇪 xhttp", "🇩🇪 trojan-grpc"}


# --- ключи WireGuard --------------------------------------------------------

def _модуль():
    import importlib.util
    spec = importlib.util.spec_from_file_location("xui_profile", ИНСТРУМЕНТ)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def test_x25519_по_вектору_rfc7748():
    m = _модуль()
    k = bytes.fromhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
    u = bytes.fromhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
    assert m.x25519(k, u).hex() == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"


def test_x25519_открытый_ключ_по_вектору_rfc7748():
    """Раздел 6.1: открытый ключ Алисы из её закрытого."""
    m = _модуль()
    alice = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    assert m.x25519(alice, (9).to_bytes(32, "little")).hex() == \
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
