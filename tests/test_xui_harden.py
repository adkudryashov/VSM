"""
Защита 3x-ui-pro (tools/xui-harden.py, lib/xui_harden.sh).

Конфиги — в той форме, что сняты с главного 10.10.2026 (домены заменены).
Где на машине есть nginx, правка проверяется ИМ ЖЕ (nginx -t): регулярку с
(?!) и ssl_reject_handshake за nginx проверить не может никто, кроме nginx.
"""
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("xh", ROOT / "tools" / "xui-harden.py")
xh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xh)

INCLUDES = r"""    #Xray generic proxy (WS / gRPC by port+path)
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)$ {
        if ($hack = 1) { return 404; }
        client_max_body_size 0;
        proxy_http_version 1.1;
        if ($content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:$fwdport$is_args$args;
            break;
        }
        if ($request_method ~* ^(PUT|POST|GET)$) {
            proxy_pass http://127.0.0.1:$fwdport$is_args$args;
            break;
        }
    }

    location / { try_files $uri $uri/ =404; }
"""

STREAM = """map $ssl_preread_server_name $sni_name {
    hostnames;
    rw.example.com    xray;
    panel.example.com            www;
    default              xray;
}

upstream xray { server 127.0.0.1:8443; }
upstream www  { server 127.0.0.1:7443; }

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen     443;
    listen     [::]:443;
    proxy_pass $sni_name;
    ssl_preread on;
}
"""


def _db(tmp_path, rows):
    p = tmp_path / "x-ui.db"
    con = sqlite3.connect(p)
    con.execute("create table inbounds (port int, stream_settings text, enable int)")
    con.execute("create table settings (id integer primary key, key text, value text)")
    con.executemany("insert into inbounds values (?, ?, ?)", rows)
    con.commit()
    con.close()
    return str(p)


def ss(**kw):
    return json.dumps(kw)


ROWS = [
    (8443, ss(network="tcp", security="reality"), 1),
    (19665, ss(network="ws", wsSettings={"path": "/19665/abcdef"}), 1),
    (34130, ss(network="grpc", grpcSettings={"serviceName": "34130/xyz"}), 1),
    (0, ss(network="xhttp", xhttpSettings={"path": "/qwe"}), 1),
    (443, "{не json", 1),                                         # как на главном
    (20000, ss(network="ws", wsSettings={"path": "/custom"}), 1),  # своё правило nginx
    (21000, ss(network="ws", wsSettings={"path": "/21000/x"}), 0),  # выключено
    (22000, ss(network="httpupgrade", httpupgradeSettings={"path": "/22000/u"}), 1),
]


# ------------------------------------------------------------------ fwd
def test_нужные_порты_только_у_своих_ws_и_grpc(tmp_path):
    assert xh.fwd_wanted(_db(tmp_path, ROWS)) == [19665, 22000, 34130]


def test_пересылка_сужается_до_своих_портов():
    assert xh.fwd_state(INCLUDES) == "любой порт"
    new = xh.fwd_apply(INCLUDES, [34130, 19665])
    assert "(?<fwdport>19665|34130)/(?<fwdpath>.*)$" in new
    assert xh.fwd_state(new) == "только: 19665 34130"
    assert xh.fwd_apply(new, [19665, 34130]) == new            # повтор ничего не меняет
    # Остальное в файле не тронуто.
    assert new.replace("19665|34130", r"\d+") == INCLUDES


def test_без_своих_соединений_пересылки_нет_вовсе():
    new = xh.fwd_apply(INCLUDES, [])
    assert xh.fwd_state(new) == "никакой"
    assert xh.fwd_want_label([]) == "никакой"


def test_нет_правила_это_не_ошибка_чтения():
    assert xh.fwd_state("location / { }") == "нет правила"
    with pytest.raises(ValueError):
        xh.fwd_apply("location / { }", [1])


# ------------------------------------------------------------------ sni
def test_чужое_имя_уходит_в_обрыв():
    assert xh.sni_state(STREAM) == "в xray"
    new = xh.sni_apply(STREAM, 7449)
    assert xh.sni_state(new) == "обрыв"
    assert "default              vsm_reject;" in new
    assert new.count("upstream vsm_reject { server 127.0.0.1:7449; }") == 1
    # Свои имена ведут туда же, куда вели.
    assert "rw.example.com    xray;" in new and "panel.example.com            www;" in new
    assert xh.sni_apply(new, 7449) == new                       # повтор
    assert "127.0.0.1:7450" in xh.sni_apply(new, 7450)          # порт меняется на месте


def test_карта_без_default_получает_его():
    text = STREAM.replace("    default              xray;\n", "")
    assert xh.sni_state(xh.sni_apply(text, 7449)) == "обрыв"


def test_нет_карты():
    assert xh.sni_state("server { }") == "нет карты"
    with pytest.raises(ValueError):
        xh.sni_apply("server { }", 7449)


# ------------------------------------------------- nginx -t, если nginx есть
def _nginx_t(tmp_path, http_body="", stream_body=""):
    nginx = shutil.which("nginx")
    if not nginx:
        pytest.skip("nginx нет на этой машине")
    mods = "include /etc/nginx/modules-enabled/*.conf;" if Path("/etc/nginx/modules-enabled").is_dir() else ""
    conf = tmp_path / "nginx.conf"
    conf.write_text(f"""{mods}
pid {tmp_path}/nginx.pid;
error_log {tmp_path}/error.log;
events {{}}
http {{
    access_log off;
    client_body_temp_path {tmp_path}; proxy_temp_path {tmp_path};
    fastcgi_temp_path {tmp_path}; uwsgi_temp_path {tmp_path}; scgi_temp_path {tmp_path};
    {http_body}
}}
{('stream { ' + stream_body + ' }') if stream_body else ''}
""")
    # Без -p: модули в modules-enabled подключены путями относительно
    # префикса сборки, и с чужим префиксом nginx их не находит (10.10.2026).
    r = subprocess.run([nginx, "-t", "-c", str(conf)],
                       capture_output=True, text=True)
    return r.returncode, r.stderr


def test_nginx_принимает_суженную_пересылку(tmp_path):
    for ports in ([19665, 34130], []):
        body = 'map $request_uri $hack { default 0; }\nserver { listen 127.0.0.1:18080;\n' \
               + xh.fwd_apply(INCLUDES, ports) + "}"
        rc, err = _nginx_t(tmp_path, http_body=body)
        assert rc == 0, err


def test_nginx_принимает_обрыв_чужого_имени(tmp_path):
    if not Path("/etc/nginx/modules-enabled").is_dir():
        pytest.skip("модуль stream подключается только в боевой раскладке")
    stream = xh.sni_apply(STREAM, 17449).replace("listen     443;", "listen 127.0.0.1:18443;") \
        .replace("listen     [::]:443;", "")
    rc, err = _nginx_t(tmp_path, http_body=xh.sni_reject_conf(17449), stream_body=stream)
    assert rc == 0, err


# -------------------------------------------------------------- listen
def test_состояние_панели(tmp_path):
    db = _db(tmp_path, ROWS)
    assert xh.listen_state(db) == "панель все · подписка все"
    con = sqlite3.connect(db)
    con.executemany("insert into settings (key, value) values (?, ?)",
                    [("webListen", "127.0.0.1"), ("subListen", "127.0.0.1")])
    con.commit()
    con.close()
    assert xh.listen_state(db) == xh.LISTEN_WANT


# ---------------------------------------------- bash: подмена и откат nginx
def _run_swap(tmp_path, nginx_ok: bool):
    """_xh_nginx_swap с подменённым nginx: заглушки впереди PATH — настоящий
    nginx и systemctl тест не трогает."""
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    (bin_ / "nginx").write_text(f"#!/bin/sh\nexit {0 if nginx_ok else 1}\n")
    (bin_ / "systemctl").write_text("#!/bin/sh\necho \"$@\" >> \"$LOG\"\nexit 0\n")
    for f in bin_.iterdir():
        f.chmod(0o755)
    a = tmp_path / "a.conf"
    a.write_text("старое\n")
    new_a, new_b = tmp_path / "na", tmp_path / "nb"
    new_a.write_text("новое a\n")
    new_b.write_text("новое b\n")
    b = tmp_path / "b.conf"                                     # его раньше не было
    env = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}", LOG=str(tmp_path / "log"),
               XH_BACKUP_DIR=str(tmp_path / "bak"))
    r = subprocess.run(["bash", "-c", f'. "{ROOT}/lib/xui_harden.sh"; '
                        f'_xh_nginx_swap "{a}" "{new_a}" "{b}" "{new_b}"'],
                       env=env, capture_output=True, text=True)
    return r.returncode, a, b, tmp_path


@pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")
def test_подмена_применяется_и_перезагружает(tmp_path):
    rc, a, b, t = _run_swap(tmp_path, nginx_ok=True)
    assert rc == 0
    assert a.read_text() == "новое a\n" and b.read_text() == "новое b\n"
    assert "reload nginx" in (t / "log").read_text()
    assert len(list((t / "bak").iterdir())) == 1                # копия только у бывшего файла


@pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")
def test_несобравшийся_nginx_откатывается_целиком(tmp_path):
    rc, a, b, _ = _run_swap(tmp_path, nginx_ok=False)
    assert rc != 0
    assert a.read_text() == "старое\n"
    assert not b.exists()                                       # нового файла не осталось
