"""
Брошенные права панели telemt_panel 1.0.0-rc.3 (lib/expectations.sh,
orphan_panel_rights). С rc.3 права — это sudoers плюс помощник автора и его
политика (`install.sh repair-privileges`, 11.10.2026). Панели нет — не должно
остаться ни того, ни другого. Все пути временные; MTProxyL-Panel выключена из
проверки, чтобы тест не смотрел в настоящий /etc/sudoers.d.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")


def run(tmp_path, script):
    env = dict(os.environ,
               TELEMT_PANEL_UNIT=str(tmp_path / "telemt-panel.service"),
               TELEMT_PANEL_BIN=str(tmp_path / "telemt-panel"),
               TELEMT_PANEL_SUDOERS=str(tmp_path / "sudoers.d" / "telemt-panel"),
               TELEMT_PANEL_HELPER=str(tmp_path / "libexec" / "telemt-panel-privileged"),
               TELEMT_PANEL_POLICY_DIR=str(tmp_path / "telemt-panel-privileged"),
               EXPECT_STATE=str(tmp_path / "state"), EXPECT_LOCAL=str(tmp_path / "local"))
    lib = (ROOT / "lib").as_posix()
    r = subprocess.run(["bash", "-c", f'. "{lib}/panels.sh"; . "{lib}/expectations.sh"\n'
                        "MTPL_PANEL_SUDOERS_FILES=(); panel_mtproxyl_present() { return 0; }\n" + script],
                       env=env, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr


def leftovers(tmp_path):
    (tmp_path / "sudoers.d").mkdir()
    (tmp_path / "sudoers.d" / "telemt-panel").write_text("telemt-panel ALL=(root) NOPASSWD: ...\n")
    (tmp_path / "libexec").mkdir()
    (tmp_path / "libexec" / "telemt-panel-privileged").write_text("bin")
    (tmp_path / "telemt-panel-privileged").mkdir()
    (tmp_path / "telemt-panel-privileged" / "policy.json").write_text("{}")


def test_панели_нет_остатки_видны_и_снимаются(tmp_path):
    leftovers(tmp_path)
    rc, out, _ = run(tmp_path, "read_orphan_panel_rights")
    assert out == "есть: telemt-panel telemt-panel-privileged telemt-panel-privileged"
    rc, _, err = run(tmp_path, "fix_orphan_panel_rights")
    assert rc == 0, err
    assert not (tmp_path / "sudoers.d" / "telemt-panel").exists()
    assert not (tmp_path / "libexec" / "telemt-panel-privileged").exists()
    assert not (tmp_path / "telemt-panel-privileged").exists()
    assert run(tmp_path, "read_orphan_panel_rights")[1] == "нет"


def test_панель_стоит_права_не_трогаем(tmp_path):
    leftovers(tmp_path)
    (tmp_path / "telemt-panel").write_text("#!/bin/sh\n")
    (tmp_path / "telemt-panel").chmod(0o755)
    assert run(tmp_path, "read_orphan_panel_rights")[1] == "нет"
    assert run(tmp_path, "fix_orphan_panel_rights")[0] == 0
    assert (tmp_path / "telemt-panel-privileged" / "policy.json").exists()
