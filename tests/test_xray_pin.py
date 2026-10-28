"""
Закрепление ядра Xray в 3x-ui (lib/xray_pin.sh, 28.10.2026).

ЗАЧЕМ. Подмена ядра — это перезапуск x-ui со всеми подключениями. Ошибка тут
оставляет сервер без единого входящего, поэтому у каждого пути проверяется
итог на диске: какое ядро лежит после отказа и есть ли копия.

curl, systemctl и pgrep подменены заглушками впереди PATH; «ядро» — сценарий
sh, печатающий свою версию. Настоящий x-ui не трогается.
"""
import hashlib
import io
import os
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not (shutil.which("bash") and shutil.which("python3")),
                                reason="нужны bash и python3")


def ядро(version, test_ok=True):
    return (f'#!/bin/sh\n'
            f'if [ "$1" = version ]; then echo "Xray {version} (Xray, Penetrates Everything.)"; exit 0; fi\n'
            f'if [ "$1" = run ] && [ "$2" = -test ]; then exit {0 if test_ok else 23}; fi\n'
            f'exit 0\n')


def архив(version, test_ok=True):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("xray", ядро(version, test_ok))
        z.writestr("geoip.dat", "")
    return buf.getvalue()


CURL = """#!/bin/sh
echo "curl $*" >> "$LOG"
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
case "$url" in
    *.dgst) echo "SHA2-256= $DGST" ;;
    *) cp "$ZIP" "$out" ;;
esac
"""

SYSTEMCTL = """#!/bin/sh
echo "systemctl $*" >> "$LOG"
[ "$1" = is-active ] && exit "${ACTIVE_RC:-0}"
exit 0
"""


def run(tmp_path, script, *, cur="26.10.21", zip_bytes=None, dgst=None, active_rc=0):
    b = tmp_path / "bin"; b.mkdir(exist_ok=True)
    xb = tmp_path / "xui"; xb.mkdir(exist_ok=True)
    core = xb / "xray-linux-amd64"
    if not core.exists():
        core.write_text(ядро(cur)); core.chmod(0o755)
        (xb / "config.json").write_text("{}")
    zp = tmp_path / "x.zip"
    if zip_bytes is not None:
        zp.write_bytes(zip_bytes)
    for name, body in (("curl", CURL), ("systemctl", SYSTEMCTL), ("pgrep", "#!/bin/sh\nexit 0\n"),
                       ("uname", "#!/bin/sh\necho x86_64\n")):
        (b / name).write_text(body); (b / name).chmod(0o755)
    env = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", LOG=str(tmp_path / "log"),
               ZIP=str(zp), DGST=dgst or "", ACTIVE_RC=str(active_rc),
               XRAY_PIN_BIN_DIR=str(xb), XRAY_PIN_BACKUP_DIR=str(tmp_path / "backup"),
               XRAY_PIN_WAIT="2")
    r = subprocess.run(["bash", "-c", f'. "{(ROOT / "lib" / "xray_pin.sh").as_posix()}"\n{script}'],
                       env=env, capture_output=True, text=True)
    log = (tmp_path / "log").read_text() if (tmp_path / "log").exists() else ""
    return r.returncode, r.stdout.strip(), r.stderr, log, core


def версия(core):
    return subprocess.run([str(core), "version"], capture_output=True, text=True).stdout.split()[1]


def test_уже_та_версия_ничего_не_качает(tmp_path):
    rc, _, err, log, core = run(tmp_path, "xray_pin_apply 26.7.28", cur="26.7.28")
    assert rc == 0, err
    assert "curl" not in log and "restart" not in log


def test_подмена_с_копией_и_перезапуском(tmp_path):
    z = архив("9.9.9")
    rc, _, err, log, core = run(tmp_path, "xray_pin_apply 9.9.9", zip_bytes=z,
                                dgst=hashlib.sha256(z).hexdigest())
    assert rc == 0, err
    assert версия(core) == "9.9.9"
    assert (tmp_path / "backup" / "xray-linux-amd64.26.10.21").exists()
    assert "systemctl restart x-ui" in log


def test_закреплённая_версия_сверяется_со_своей_записью(tmp_path):
    # Свой архив под именем 26.7.28: .dgst «подтверждает» его, но запись в
    # библиотеке — нет. Ядро должно остаться прежним.
    z = архив("26.7.28")
    rc, _, err, log, core = run(tmp_path, "xray_pin_apply 26.7.28", zip_bytes=z,
                                dgst=hashlib.sha256(z).hexdigest())
    assert rc != 0
    assert "сумма" in err
    assert версия(core) == "26.10.21"
    assert ".dgst" not in log


def test_чужая_сумма_ядро_не_трогает(tmp_path):
    rc, _, err, log, core = run(tmp_path, "xray_pin_apply 9.9.9", zip_bytes=архив("9.9.9"),
                                dgst="0" * 64)
    assert rc != 0
    assert версия(core) == "26.10.21"
    assert "restart" not in log


def test_конфиг_не_принят_ядро_не_трогает(tmp_path):
    z = архив("9.9.9", test_ok=False)
    rc, _, err, log, core = run(tmp_path, "xray_pin_apply 9.9.9", zip_bytes=z,
                                dgst=hashlib.sha256(z).hexdigest())
    assert rc != 0
    assert "не принимает конфиг" in err
    assert версия(core) == "26.10.21"
    assert "restart" not in log


def test_не_поднялось_старое_возвращается(tmp_path):
    z = архив("9.9.9")
    rc, _, err, log, core = run(tmp_path, "xray_pin_apply 9.9.9", zip_bytes=z,
                                dgst=hashlib.sha256(z).hexdigest(), active_rc=3)
    assert rc != 0
    assert "возвращено 26.10.21" in err
    assert версия(core) == "26.10.21"
    assert log.count("systemctl restart x-ui") == 2


def test_пустая_версия_значит_не_закреплять(tmp_path):
    rc, _, err, log, core = run(tmp_path, 'XRAY_PIN_VERSION=""; xray_pin_apply')
    assert rc == 0, err
    assert log == ""
