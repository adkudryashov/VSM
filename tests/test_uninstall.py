"""
Удаление VSM: что снимается, что остаётся и чем это подтверждается.

ЗАЧЕМ. 31.10.2026 разбор показал, что uninstall.sh не снимал собственные
таймеры VSM (vsm-heartbeat.timer, vsm-backup.timer), оставлял /etc/vsm с
паролями панелей и чистил ~/.bashrc по подстроке «vsm» — вместе с чужими
алиасами и PATH. Отчёт при этом был бодрый.

Проверки идут на подставных каталогах: все пути uninstall.sh берёт из
VSM_*-переменных, systemctl подменён заглушкой впереди PATH. Настоящая
установка и настоящие юниты не затрагиваются.
"""
import os
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "uninstall.sh"
BASH = shutil.which("bash")

pytestmark = pytest.mark.skipif(BASH is None, reason="нужен bash")

BASHRC_LINE = "if [[ -t 0 ]]; then vsm; fi"
BASHRC_COMMENT = "# Автозапуск основного меню"

BASHRC = f"""\
# мой .bashrc
alias vsm2='echo hi'
export PATH=$PATH:/opt/vsm/bin
{BASHRC_COMMENT}
{BASHRC_LINE}
"""


@pytest.fixture
def stand(tmp_path):
    """Подставная установка: каталоги, юниты, .bashrc и заглушка systemctl."""
    target = tmp_path / "root" / "VSM"
    (target / "bots" / "data").mkdir(parents=True)
    (target / "vsm").write_text("#!/bin/bash\n", encoding="utf-8")
    (target / "bots" / "data" / "ip_history.db").write_text("x", encoding="utf-8")

    etc = tmp_path / "etc" / "vsm"
    etc.mkdir(parents=True)
    (etc / "telemt.conf").write_text("TELEMT_SECRET=x\n", encoding="utf-8")
    (etc / "bots.conf").write_text("BOTS_MODE=combined\n", encoding="utf-8")

    backup = tmp_path / "var" / "backups" / "vsm"
    backup.mkdir(parents=True)
    (backup / "config-2026-10-31.tar.gz").write_text("x", encoding="utf-8")

    units = tmp_path / "units"
    units.mkdir()
    for unit in ("vsm-heartbeat.timer", "vsm-backup.timer",
                 "vsm-backup.service", "3xui-telemt-bot.service"):
        (units / unit).write_text("[Unit]\n", encoding="utf-8")

    mapdir = tmp_path / "www" / "telemt-map"
    mapdir.mkdir(parents=True)
    (mapdir / "map.html").write_text("<html></html>", encoding="utf-8")

    home = tmp_path / "home"
    home.mkdir()
    (home / ".bashrc").write_text(BASHRC, encoding="utf-8")

    bindir = tmp_path / "bin"
    bindir.mkdir()
    log = tmp_path / "systemctl.log"
    stub = bindir / "systemctl"
    stub.write_text('#!/bin/bash\necho "$@" >> "$SYSTEMCTL_LOG"\nexit 0\n', encoding="utf-8")
    stub.chmod(0o755)

    env = os.environ.copy()
    env.update({
        "HOME": str(home),
        "PATH": f"{bindir}{os.pathsep}{env.get('PATH', '')}",
        "SYSTEMCTL_LOG": str(log),
        "VSM_UNINSTALL_FORCE": "1",
        "VSM_TARGET_DIR": str(target),
        "VSM_ETC_DIR": str(etc),
        "VSM_BACKUP_DIR": str(backup),
        "VSM_UNIT_DIR": str(units),
        "VSM_MAP_DIR": str(mapdir),
        "VSM_BASHRC": str(home / ".bashrc"),
    })
    return SimpleNamespace(tmp=tmp_path, target=target, etc=etc, backup=backup,
                           units=units, mapdir=mapdir, home=home, log=log, env=env)


def run(stand, answers):
    return subprocess.run(
        [BASH, str(SCRIPT)],
        input=answers,
        text=True,
        capture_output=True,
        timeout=90,
        cwd=str(stand.tmp),
        env=stand.env,
    )


# ------------------------------------------------------------------ полное удаление
def test_снимает_всё_что_поставил_сам(stand):
    итог = run(stand, "УДАЛИТЬ\nУДАЛИТЬ\nДА\n")
    assert итог.returncode == 0, итог.stdout + итог.stderr

    assert not stand.target.exists(), "каталог репозитория остался"
    assert not stand.etc.exists(), "секреты /etc/vsm остались"
    assert not stand.backup.exists(), "суточные копии остались"
    assert not stand.mapdir.exists(), "карта подключений осталась"
    for unit in ("vsm-heartbeat.timer", "vsm-backup.timer",
                 "vsm-backup.service", "3xui-telemt-bot.service"):
        assert not (stand.units / unit).exists(), f"юнит {unit} остался"

    журнал = stand.log.read_text(encoding="utf-8")
    assert "disable --now vsm-heartbeat.timer" in журнал
    assert "disable --now vsm-backup.timer" in журнал
    assert "daemon-reload" in журнал

    assert "Удаление завершено" in итог.stdout


def test_автозапуск_убран_а_чужие_строки_с_vsm_остались(stand):
    """
    Прежняя версия делала `sed -i '/vsm/d'` — и уносила алиас vsm2 и PATH с
    каталогом /opt/vsm/bin. Удаляться обязана ровно строка автозапуска.
    """
    run(stand, "УДАЛИТЬ\nУДАЛИТЬ\nДА\n")
    bashrc = (stand.home / ".bashrc").read_text(encoding="utf-8")

    assert BASHRC_LINE not in bashrc
    assert BASHRC_COMMENT not in bashrc
    assert "alias vsm2='echo hi'" in bashrc
    assert "/opt/vsm/bin" in bashrc
    assert (stand.home / ".bashrc.vsm-bak").exists(), "копия .bashrc не сделана"


# ------------------------------------------------------------------ отказ
def test_отказ_оставляет_данные_на_месте(stand):
    """
    Отказ на вопросы сохраняет то, что просили сохранить. Свои таймеры при
    этом снимаются всегда: они часть VSM, а не данных владельца, и после
    удаления меню всё равно дёргали бы отсутствующие скрипты.
    """
    # Три вопроса: боты, каталог, секреты. Ни на один не отвечаем словом.
    итог = run(stand, "нет\nнет\nнет\n")
    assert итог.returncode == 0, итог.stdout + итог.stderr

    assert stand.target.exists()
    assert stand.etc.exists()
    assert stand.backup.exists()
    assert not (stand.units / "vsm-heartbeat.timer").exists()
    assert (stand.units / "3xui-telemt-bot.service").exists()
    assert "каталог сохранён" in итог.stdout
    assert "секреты и копии сохранены" in итог.stdout


def test_чужое_слово_не_считается_подтверждением(stand):
    итог = run(stand, "удалить\nудалить\nда\n")
    assert stand.target.exists(), "регистр не должен учитываться"
    assert stand.etc.exists()
    assert "Удаление завершено" in итог.stdout


# ------------------------------------------------------------------ .bashrc без блока
def test_чужой_bashrc_не_трогается(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    исходный = "# только мои строки\nalias vsm2='echo hi'\n"
    (home / ".bashrc").write_text(исходный, encoding="utf-8")

    env = os.environ.copy()
    env.update({
        "HOME": str(home),
        "VSM_UNINSTALL_FORCE": "1",
        "VSM_TARGET_DIR": str(tmp_path / "нет-такого"),
        "VSM_ETC_DIR": str(tmp_path / "нет-и-такого"),
        "VSM_BACKUP_DIR": str(tmp_path / "тоже-нет"),
        "VSM_UNIT_DIR": str(tmp_path / "units"),
        "VSM_MAP_DIR": str(tmp_path / "map"),
        "VSM_BASHRC": str(home / ".bashrc"),
    })
    итог = subprocess.run([BASH, str(SCRIPT)], input="", text=True,
                          capture_output=True, timeout=60, cwd=str(tmp_path), env=env)
    assert итог.returncode == 0, итог.stdout + итог.stderr
    assert (home / ".bashrc").read_text(encoding="utf-8") == исходный
    assert "автозапуска VSM" in итог.stdout


# ------------------------------------------------------------------ общий признак
def test_установщик_и_удалятор_знают_одну_строку():
    """
    install.sh дописывает строку, uninstall.sh её снимает. Разойдись они —
    автозапуск перестанет удаляться, и заметить это будет нечем.
    """
    установщик = (ROOT / "install.sh").read_text(encoding="utf-8")
    удалятор = (ROOT / "uninstall.sh").read_text(encoding="utf-8")
    assert BASHRC_LINE in установщик
    assert BASHRC_LINE in удалятор
    assert BASHRC_COMMENT in установщик
    assert BASHRC_COMMENT in удалятор
