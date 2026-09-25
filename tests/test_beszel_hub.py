"""
Хаб beszel: конфиг nginx и то, как VSM потом читает из него адрес.

ЗАЧЕМ. На 179 (nginx 1.24) «http2 on;» не прошёл nginx -t, а на 26.04 (1.28)
старая форма «listen … http2» устарела — конфиг обязан выбирать форму по
версии. Без IPv6 в ядре строка «listen [::]» роняет nginx целиком, вместе с
панелью и маской. И адрес хаба на экране «Доступы и домены» читается обратно
из этого же файла — формат записи и чтения должны сходиться.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
LIB = КОРЕНЬ / "lib"

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="нужен bash")


def _bash(код, **env):
    полный = "\n".join([
        f'source "{(LIB / "beszel_agent.sh").as_posix()}"',
        f'source "{(LIB / "beszel_hub.sh").as_posix()}"',
        код,
    ])
    r = subprocess.run(["bash", "-c", полный], capture_output=True, text=True,
                       env={"PATH": "/usr/bin:/bin", **env})
    assert r.returncode == 0, r.stderr
    return r.stdout


def _конфиг(tmp_path, версия, ipv6):
    inet6 = tmp_path / "if_inet6"
    if ipv6:
        inet6.write_text("")
    return _bash('beszel_hub_nginx_render hub.example.com 8445',
                 BESZEL_HUB_NGINX_VERSION=версия,
                 BESZEL_HUB_IF_INET6=str(inet6))


def test_новый_nginx_http2_отдельной_строкой(tmp_path):
    к = _конфиг(tmp_path, "1.28.3", ipv6=True)
    assert "    http2 on;" in к
    assert "ssl http2" not in к


def test_старый_nginx_http2_в_listen(tmp_path):
    к = _конфиг(tmp_path, "1.24.0", ipv6=True)
    assert "http2 on;" not in к
    assert "listen 8445 ssl http2;" in к


def test_граница_версии(tmp_path):
    assert "http2 on;" in _конфиг(tmp_path, "1.25.1", ipv6=True)
    assert "http2 on;" not in _конфиг(tmp_path, "1.25.0", ipv6=True)


def test_без_ipv6_строк_listen_ipv6_нет(tmp_path):
    к = _конфиг(tmp_path, "1.28.3", ipv6=False)
    живые = [s for s in к.splitlines() if s.strip().startswith("listen")]
    assert живые and all("[::]" not in s for s in живые)
    с_v6 = _конфиг(tmp_path, "1.28.3", ipv6=True)
    assert "    listen [::]:8445 ssl;" in с_v6


def test_по_ip_отказ_на_рукопожатии(tmp_path):
    к = _конфиг(tmp_path, "1.28.3", ipv6=True)
    перв = к.index("default_server")
    assert "ssl_reject_handshake on;" in к[перв:к.index("server_name")]


def test_хаб_только_через_петлю(tmp_path):
    к = _конфиг(tmp_path, "1.28.3", ipv6=True)
    pp = [s.strip() for s in к.splitlines() if "proxy_pass" in s]
    assert pp and all(s == "proxy_pass http://127.0.0.1:8090;" for s in pp)


@pytest.mark.parametrize("версия", ["1.24.0", "1.28.3"])
def test_адрес_читается_обратно(tmp_path, версия):
    """beszel_hub_url берёт server_name и порт из того же файла."""
    conf_d = tmp_path / "conf.d"
    conf_d.mkdir()
    (conf_d / "beszel.conf").write_text(_конфиг(tmp_path, версия, ipv6=True))
    # systemctl — заглушка: ExecStart с петлёй, как пишет наш drop-in.
    stub = tmp_path / "bin"
    stub.mkdir()
    (stub / "systemctl").write_text(
        '#!/bin/sh\necho "{ path=/opt/beszel/beszel ; argv[]=/opt/beszel/beszel '
        'serve --http 127.0.0.1:8090 ; }"\n')
    (stub / "systemctl").chmod(0o755)
    out = _bash(
        f'beszel_hub_url() {{\n{_тело_hub_url(conf_d)}\n}}\nbeszel_hub_url',
        PATH=f"{stub.as_posix()}:/usr/bin:/bin")
    assert out.strip() == "https://hub.example.com:8445"


def _тело_hub_url(conf_d):
    """Тело beszel_hub_url с каталогом conf.d теста вместо /etc/nginx."""
    текст = (LIB / "beszel_agent.sh").read_text(encoding="utf-8")
    начало = текст.index("beszel_hub_url() {") + len("beszel_hub_url() {")
    конец = текст.index("\n}\n", начало)
    тело = текст[начало:конец]
    тело = тело.replace("/etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*",
                        f"{conf_d.as_posix()}/*.conf")
    assert conf_d.as_posix() in тело
    return тело
