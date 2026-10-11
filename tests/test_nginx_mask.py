"""
Маска telemt без имени (lib/nginx_mask.sh).

telemt обрывает чужое имя сам, а приветствие TLS без имени пропускает к маске:
до 11.10.2026 единственный server{} на порту маски был сервером по умолчанию и
отдавал сертификат с доменом панели. Теперь рядом стоит сервер по умолчанию с
ssl_reject_handshake. Где на машине есть nginx и openssl, собранный файл
проверяется самим nginx -t.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIB = (ROOT / "lib" / "nginx_mask.sh").as_posix()

pytestmark = pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")


def sh(script, env=None):
    r = subprocess.run(["bash", "-c", f'. "{LIB}"\n{script}'],
                       env=dict(os.environ, **(env or {})), capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def render(reject, cert="/c.pem", key="/k.pem"):
    rc, out, err = sh(f'nginx_mask_render 7444 panel.example.com /var/www/html '
                      f'"{cert}" "{key}" " http2" "    ssl_protocols TLSv1.2 TLSv1.3;" "{reject}"')
    assert rc == 0, err
    return out


def test_без_имени_обрыв_свой_домен_на_месте():
    out = render("1")
    # Сервер по умолчанию — только обрывающий; блок маски им не стал.
    assert out.count("default_server") == 1
    assert "listen 127.0.0.1:7444 ssl http2 default_server;" in out
    assert "ssl_reject_handshake on;" in out
    assert "listen 127.0.0.1:7444 ssl http2;" in out
    assert "server_name panel.example.com;" in out


def test_без_поддержки_блока_нет():
    out = render("")
    assert "ssl_reject_handshake" not in out and "default_server" not in out


def _stub_nginx(tmp_path, version):
    b = tmp_path / "bin"
    b.mkdir()
    (b / "nginx").write_text(f'#!/bin/sh\necho "nginx version: nginx/{version}" >&2\n')
    (b / "nginx").chmod(0o755)
    return {"PATH": f"{b}:{os.environ['PATH']}"}


@pytest.mark.parametrize("version,ok", [
    ("1.18.0", False), ("1.19.3", False), ("1.19.4", True),
    ("1.24.0", True), ("1.28.3 (Ubuntu)", True), ("1.100.0", True),
])
def test_версия_nginx(tmp_path, version, ok):
    rc, _, _ = sh("nginx_mask_reject_supported", _stub_nginx(tmp_path, version))
    assert (rc == 0) is ok


def test_состояние_маски(tmp_path):
    f = tmp_path / "mask.conf"
    env = {"MASK_PATH": str(f)}
    get = 'MASK_VHOST="$MASK_PATH"; nginx_mask_reject_state'
    assert sh(get, env)[1].strip() == "нет маски"
    f.write_text(render(""))
    assert sh(get, env)[1].strip() == "сертификат"
    f.write_text(render("1"))
    assert sh(get, env)[1].strip() == "обрыв"
    # Закомментированная директива не в счёт.
    f.write_text(render("").replace("index index.html", "# ssl_reject_handshake on;\n    index index.html"))
    assert sh(get, env)[1].strip() == "сертификат"


def test_nginx_принимает_маску_с_обрывом(tmp_path):
    nginx, openssl = shutil.which("nginx"), shutil.which("openssl")
    if not nginx or not openssl:
        pytest.skip("нужны nginx и openssl")
    cert, key = tmp_path / "c.pem", tmp_path / "k.pem"
    subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=panel.example.com", "-keyout", str(key), "-out", str(cert)],
                   check=True, capture_output=True)
    rc0, _, _ = sh("nginx_mask_reject_supported")
    vhost = render("1" if rc0 == 0 else "", cert, key).replace("7444", "17444")
    conf = tmp_path / "nginx.conf"
    conf.write_text(f"""pid {tmp_path}/nginx.pid;
error_log {tmp_path}/error.log;
events {{}}
http {{
    access_log off;
    client_body_temp_path {tmp_path}; proxy_temp_path {tmp_path};
    fastcgi_temp_path {tmp_path}; uwsgi_temp_path {tmp_path}; scgi_temp_path {tmp_path};
{vhost}
}}
""")
    r = subprocess.run([nginx, "-t", "-c", str(conf)], capture_output=True, text=True)
    if r.returncode and "http2" in r.stderr and "unknown" in r.stderr:
        pytest.skip("nginx без модуля http2")
    assert r.returncode == 0, r.stderr
