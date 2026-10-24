"""
Позиция реестра avail_enabled (lib/expectations.sh, 24.10.2026): расписание
проверки доступности в MTProxyL включено. С MTProxyL 1.7.12 после установки
оно выключено, а сторож бота читает именно его вердикт. mtproxyl подменён
заглушкой: статус берётся из файла, вызовы пишутся в журнал.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not (shutil.which("bash") and shutil.which("python3")),
                                reason="нужны bash и python3")

STUB = """#!/bin/sh
echo "$@" >> "$LOG"
if [ "$1 $2" = "availability status" ]; then cat "$STATUS"; fi
if [ "$1 $2" = "availability on" ]; then
    printf '{"enabled":true,"auto_check":true,"interval":%s,"probes":20}\\n' "$3" > "$STATUS"
fi
exit 0
"""


def run(tmp_path, script, status='{"enabled":true,"auto_check":false,"interval":30,"probes":20}',
        env_file=""):
    b = tmp_path / "bin"
    b.mkdir(exist_ok=True)
    (b / "mtproxyl").write_text(STUB)
    (b / "mtproxyl").chmod(0o755)
    st = tmp_path / "status.json"
    if not st.exists():
        st.write_text(status)
    (tmp_path / "bots.env").write_text(env_file)
    env = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", LOG=str(tmp_path / "log"),
               STATUS=str(st), VSM_BOTS_ENV=str(tmp_path / "bots.env"),
               EXPECT_STATE=str(tmp_path / "state"), EXPECT_LOCAL=str(tmp_path / "local"))
    r = subprocess.run(["bash", "-c", f'. "{(ROOT / "lib" / "expectations.sh").as_posix()}"\n{script}'],
                       env=env, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr


def test_выключена_расхождение_и_включение(tmp_path):
    assert run(tmp_path, "read_avail_enabled")[1] == "выключена"
    rc, _, err = run(tmp_path, "fix_avail_enabled")
    assert rc == 0, err
    assert "availability on 30" in (tmp_path / "log").read_text()   # период тот же, что в реестре
    assert run(tmp_path, '[ "$(read_avail_enabled)" = "$(want_avail_enabled)" ] && echo ok')[1] == "ok"


def test_включена_сходится(tmp_path):
    out = run(tmp_path, "read_avail_enabled",
              status='{"enabled":true,"auto_check":true,"interval":30,"probes":20}')[1]
    assert out == "включена"


def test_бот_меряет_сам_позиция_не_применима(tmp_path):
    out = run(tmp_path, 'applies_avail_enabled && echo да || echo нет',
              env_file="ADMIN_IDS=1\nRU_CHECK_SOURCE=self\n")[1]
    assert out == "нет"
    out = run(tmp_path, 'applies_avail_enabled && echo да || echo нет',
              env_file="RU_CHECK_SOURCE=mtproxyl\n")[1]
    assert out == "да"


def test_нечитаемый_статус_не_выдаётся_за_выключенный(tmp_path):
    assert run(tmp_path, "read_avail_enabled", status="мусор")[1] == "не прочитать"
