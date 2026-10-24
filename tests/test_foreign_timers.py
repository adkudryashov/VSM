"""
Позиция реестра foreign_timers (lib/expectations.sh): какие таймеры считаются
чужими. Штатные системные и свои (vsm-) в список не попадают; таймеры mdadm —
тоже (23–24.10.2026: появлялись после обновления пакета и пропадали после
перезагрузки на сервере без RAID). systemctl подменён заглушкой.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")

LIST_TIMERS = """\
Sat 2026-10-24 06:26:30 CEST 8h - - apt-daily-upgrade.timer apt-daily-upgrade.service
Sat 2026-10-24 07:15:34 CEST 9h - - mdcheck_continue.timer mdcheck_continue.service
Sun 2026-11-01 18:32:42 CET 1 week - - mdcheck_start.timer mdcheck_start.service
Sat 2026-10-24 20:47:53 CEST 23h - - mdmonitor-oneshot.timer mdmonitor-oneshot.service
Sat 2026-10-24 00:00:00 CEST 3h - - logrotate.timer logrotate.service
Sat 2026-10-24 00:10:00 CEST 3h - - vsm-heartbeat.timer vsm-heartbeat.service
Sat 2026-10-24 00:14:00 CEST 3h - - mtproxyl-availability.timer mtproxyl-availability.service
Sat 2026-10-24 01:00:00 CEST 4h - - certbot.timer certbot.service
"""


def test_mdadm_и_штатные_не_чужие(tmp_path):
    b = tmp_path / "bin"
    b.mkdir()
    (tmp_path / "timers.txt").write_text(LIST_TIMERS)
    (b / "systemctl").write_text(f'#!/bin/sh\ncat "{(tmp_path / "timers.txt").as_posix()}"\n')
    (b / "systemctl").chmod(0o755)
    env = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}",
               EXPECT_STATE=str(tmp_path / "state"), EXPECT_LOCAL=str(tmp_path / "local"))
    r = subprocess.run(["bash", "-c", f'. "{(ROOT / "lib" / "expectations.sh").as_posix()}"\nread_foreign_timers'],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "certbot.service mtproxyl-availability.service"
