"""
Позиция реестра telemt_mask (lib/expectations.sh): четыре ключа [censorship],
среди них unknown_sni_action (11.10.2026). Починка дописывает недостающий ключ
и перезапускает telemt — systemctl подменён заглушкой, живой движок тест не
трогает.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")

TOML = """[general]
use_middle_proxy = true

[censorship]
mask_port = 7444
mask_host = "127.0.0.1"
mask = true
tls_domain = "panel.example.com"

[access.users]
hello = "00000000000000000000000000000000"
"""


def run(tmp_path, script):
    b = tmp_path / "bin"
    b.mkdir(exist_ok=True)
    (b / "systemctl").write_text('#!/bin/sh\necho "$@" >> "$LOG"\nexit 0\n')
    (b / "systemctl").chmod(0o755)
    (tmp_path / "telemt.conf").write_text("TELEMT_MASK_PORT=7444\n")
    env = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", LOG=str(tmp_path / "log"),
               TELEMT_TOML=str(tmp_path / "telemt.toml"), VSM_TELEMT_CONF=str(tmp_path / "telemt.conf"),
               EXPECT_STATE=str(tmp_path / "state"), EXPECT_LOCAL=str(tmp_path / "local"))
    r = subprocess.run(["bash", "-c", f'. "{(ROOT / "lib" / "expectations.sh").as_posix()}"\n{script}'],
                       env=env, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr


def test_без_ключа_расхождение_и_починка(tmp_path):
    toml = tmp_path / "telemt.toml"
    toml.write_text(TOML)
    toml.chmod(0o640)
    rc, out, _ = run(tmp_path, 'echo "$(read_telemt_mask)|$(want_telemt_mask)"')
    got, want = out.split("|")
    assert got == "true 127.0.0.1 7444 " and want == "true 127.0.0.1 7444 reject_handshake"

    rc, _, err = run(tmp_path, "fix_telemt_mask")
    assert rc == 0, err
    text = toml.read_text()
    censorship = text.split("[censorship]")[1].split("[access.users]")[0]
    assert 'unknown_sni_action = "reject_handshake"' in censorship
    assert oct(toml.stat().st_mode & 0o777) == "0o640"           # права не потеряны
    assert "restart telemt" in (tmp_path / "log").read_text()
    rc, out, _ = run(tmp_path, '[ "$(read_telemt_mask)" = "$(want_telemt_mask)" ] && echo ok')
    assert out == "ok"


def test_чужое_значение_возвращается(tmp_path):
    toml = tmp_path / "telemt.toml"
    toml.write_text(TOML.replace('mask = true\n', 'mask = true\nunknown_sni_action = "drop"\n'))
    rc, out, _ = run(tmp_path, "read_telemt_mask")
    assert out.endswith(" drop")
    assert run(tmp_path, "fix_telemt_mask")[0] == 0
    assert toml.read_text().count("unknown_sni_action") == 1
    assert 'unknown_sni_action = "reject_handshake"' in toml.read_text()
