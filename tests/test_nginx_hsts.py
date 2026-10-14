"""
HSTS (lib/xui_harden.sh, позиция реестра nginx_hsts, 14.10.2026). Файл
conf.d/vsm-hsts.conf собирается целиком: нет — появляется, чужой — заменяется,
свой — не трогается и nginx не перезагружается. nginx и systemctl подменены
заглушками впереди PATH, пути временные — живой nginx тест не трогает.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")


def run(tmp_path, script, nginx_ok=True):
    b = tmp_path / "bin"
    b.mkdir(exist_ok=True)
    (b / "nginx").write_text(f"#!/bin/sh\nexit {0 if nginx_ok else 1}\n")
    (b / "systemctl").write_text('#!/bin/sh\necho "$@" >> "$LOG"\nexit 0\n')
    for f in b.iterdir():
        f.chmod(0o755)
    (tmp_path / "conf.d").mkdir(exist_ok=True)
    env = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", LOG=str(tmp_path / "log"),
               XH_NGINX=str(tmp_path), XH_BACKUP_DIR=str(tmp_path / "bak"),
               EXPECT_STATE=str(tmp_path / "state"), EXPECT_LOCAL=str(tmp_path / "local"))
    lib = (ROOT / "lib").as_posix()
    r = subprocess.run(["bash", "-c", f'. "{lib}/xui_harden.sh"; . "{lib}/expectations.sh"\n{script}'],
                       env=env, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr


def reloads(tmp_path):
    log = tmp_path / "log"
    return log.read_text().count("reload nginx") if log.exists() else 0


def test_нет_файла_появляется_и_сверка_сходится(tmp_path):
    assert run(tmp_path, "read_nginx_hsts")[1] == "нет"
    rc, _, err = run(tmp_path, "fix_nginx_hsts")
    assert rc == 0, err
    text = (tmp_path / "conf.d" / "vsm-hsts.conf").read_text()
    assert 'on      "max-age=31536000";' in text
    assert 'default "";' in text                                   # на 80 не уходит
    assert "add_header Strict-Transport-Security $vsm_hsts always;" in text
    assert reloads(tmp_path) == 1
    assert run(tmp_path, '[ "$(read_nginx_hsts)" = "$(want_nginx_hsts)" ] && echo ok')[1] == "ok"


def test_свой_файл_не_трогается(tmp_path):
    run(tmp_path, "fix_nginx_hsts")
    assert run(tmp_path, "fix_nginx_hsts")[0] == 0
    assert reloads(tmp_path) == 1                                  # второй раз без перезагрузки


def test_чужая_правка_возвращается(tmp_path):
    run(tmp_path, "fix_nginx_hsts")
    conf = tmp_path / "conf.d" / "vsm-hsts.conf"
    conf.write_text(conf.read_text().replace("31536000", "60"))
    assert run(tmp_path, "read_nginx_hsts")[1] == "другой"
    assert run(tmp_path, "fix_nginx_hsts")[0] == 0
    assert "31536000" in conf.read_text()


def test_nginx_не_принял_файла_не_остаётся(tmp_path):
    rc, _, _ = run(tmp_path, "fix_nginx_hsts", nginx_ok=False)
    assert rc != 0
    assert not (tmp_path / "conf.d" / "vsm-hsts.conf").exists()


def test_без_conf_d_позиция_не_применима(tmp_path):
    rc, out, _ = run(tmp_path, 'rmdir "$XH_NGINX/conf.d"; applies_nginx_hsts && echo да || echo нет')
    assert out == "нет"
