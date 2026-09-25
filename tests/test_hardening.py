"""
Защита сервера: лестница бана подбора SSH и автообновления (lib/hardening.sh).

ЗАЧЕМ. Лестница держится на трёх числах, разнесённых по двум файлам: множители
сроков, память истории банов и порог попыток. Ошибка в любом не видна снаружи —
fail2ban просто банит по-другому. Память короче года молча превращает лестницу
в вечные 15 минут. Состояние читается у самого fail2ban, а не из файлов, — его
разбор проверяется заглушками. Файл apt обязан сортироваться ПОСЛЕ файла
хостера, иначе хостер перекрывает нас и обновления так и не включаются.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
LIB = КОРЕНЬ / "lib"

BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="нужен bash")


def _bash(код, tmp_path=None, заглушки=None, **env):
    path = "/usr/bin:/bin"
    if заглушки:
        stub = tmp_path / "bin"
        stub.mkdir(exist_ok=True)
        for имя, тело in заглушки.items():
            f = stub / имя
            f.write_text("#!/bin/bash\n" + тело + "\n", encoding="utf-8")
            f.chmod(0o755)
        path = f"{stub.as_posix()}:{path}"
    полный = f'source "{(LIB / "hardening.sh").as_posix()}"\n{код}'
    r = subprocess.run([BASH, "-c", полный], capture_output=True, text=True,
                       env={"PATH": path, **env})
    return r


# --- Содержимое файлов ---------------------------------------------------

def _ini(текст):
    return {k.strip(): v.strip() for k, v in
            (s.split("=", 1) for s in текст.splitlines()
             if "=" in s and not s.lstrip().startswith("#"))}


def test_лестница_сроков():
    r = _bash("ssh_ladder_render_jail")
    assert r.returncode == 0, r.stderr
    к = _ini(r.stdout)
    assert "[sshd]" in r.stdout
    assert к["maxretry"] == "3" and к["findtime"] == "1h" and к["bantime"] == "15m"
    assert к["bantime.increment"] == "true" and к["enabled"] == "true"
    # Множители × 15 минут = ступени, которые выбрал владелец.
    минуты = [int(m) * 15 for m in к["bantime.multipliers"].split()]
    assert минуты == [15, 60, 24 * 60, 7 * 24 * 60, 30 * 24 * 60, 365 * 24 * 60]


def test_память_банов_дольше_года():
    r = _bash("ssh_ladder_render_f2b")
    к = _ini(r.stdout)
    assert r.stdout.lstrip("#").find("[DEFAULT]") >= 0
    дни = int(re.fullmatch(r"(\d+)d", к["dbpurgeage"]).group(1))
    assert дни > 365
    assert int(к["dbmaxmatches"]) <= 10


def test_apt_раз_в_30_дней_без_перезагрузки():
    r = _bash("updates_render_apt")
    assert 'APT::Periodic::Unattended-Upgrade "30";' in r.stdout
    assert 'APT::Periodic::Enable "1";' in r.stdout
    assert 'Unattended-Upgrade::Automatic-Reboot "false";' in r.stdout


def test_файл_apt_читается_после_файла_хостера():
    r = _bash('echo "$HARD_APT_CONF"')
    наш = Path(r.stdout.strip()).name
    # apt читает apt.conf.d в порядке имён; последнее значение побеждает.
    assert sorted(["99-hoster-disable-automatic-apt", "99needrestart", наш])[-1] == наш


# --- Состояние по ответам fail2ban ---------------------------------------

def _f2b(inc="True", mult="1 4 96 672 2880 35040", purge="34560000", retry="3", ban="900"):
    return {
        "systemctl": 'case "$1" in is-active) exit 0;; esac; exit 0',
        "fail2ban-client": f'''
case "$*" in
  "status sshd") echo "Status for the jail: sshd"; echo "   |- Currently banned:	2";;
  "get sshd maxretry") echo {retry};;
  "get sshd bantime") echo {ban};;
  "get sshd bantime.increment") echo {inc};;
  "get sshd bantime.multipliers") echo "{mult}";;
  "get dbpurgeage") echo "Current database purge age is:"; echo "\\`- {purge}seconds";;
  *) exit 1;;
esac''',
    }


@pytest.mark.parametrize("ответы, итог", [
    ({}, "действует"),
    ({"inc": "False"}, "штатные сроки, без лестницы"),
    ({"mult": "1 2 4"}, "штатные сроки, без лестницы"),
    ({"retry": "5"}, "штатные сроки, без лестницы"),
    ({"purge": "86400"}, "лестница без памяти на год"),
])
def test_состояние_лестницы(tmp_path, ответы, итог):
    r = _bash("ssh_ladder_state", tmp_path, _f2b(**ответы))
    assert r.stdout.strip() == итог, r.stderr


def test_в_бане_сейчас(tmp_path):
    r = _bash("ssh_ladder_banned", tmp_path, _f2b())
    assert r.stdout.strip() == "2"


def test_fail2ban_нет(tmp_path):
    # PATH только из заглушек: на стенде настоящий fail2ban стоит в /usr/bin.
    r = _bash("ssh_ladder_state", tmp_path, {"systemctl": "exit 0"},
              PATH=(tmp_path / "bin").as_posix())
    assert r.stdout.strip() == "fail2ban не установлен"


@pytest.mark.parametrize("адрес", ["1.2.3.4; rm -rf /", "1.2.3.4' or 1=1", "", "host.example"])
def test_разбан_отвергает_не_адрес(tmp_path, адрес):
    журнал = tmp_path / "calls"
    r = _bash(f"ssh_ladder_unban {адрес!r}", tmp_path,
              {"fail2ban-client": f'echo "$*" >> "{журнал.as_posix()}"'})
    assert r.returncode != 0
    assert not журнал.exists(), "до fail2ban дошло то, что не адрес"


# --- Автообновления -------------------------------------------------------

def _apt(masked="", enable="1", days="30", timer_active=True):
    return {
        "unattended-upgrade": "exit 0",
        "apt-config": f'''echo 'APT::Periodic::Enable "{enable}";'
echo 'APT::Periodic::Unattended-Upgrade "{days}";' ''',
        "systemctl": f'''
case "$1" in
  is-enabled) [ "$2" = "{masked}" ] && echo masked || echo enabled;;
  is-active) exit {0 if timer_active else 3};;
esac''',
    }


@pytest.mark.parametrize("ответы, итог", [
    ({}, "раз в 30 дн."),
    ({"days": "1"}, "каждый день"),
    ({"masked": "apt-daily-upgrade.service"}, "выключены масками"),
    ({"enable": "0"}, "выключены настройкой apt"),
    ({"days": "0"}, "выключены"),
    ({"timer_active": False}, "таймер не запущен"),
])
def test_состояние_обновлений(tmp_path, ответы, итог):
    r = _bash("updates_state", tmp_path, _apt(**ответы))
    assert r.stdout.strip() == итог, r.stderr


# --- Реестр ---------------------------------------------------------------

def test_позиции_реестра_без_отметки_молчат(tmp_path):
    r = _bash(
        f'source "{(LIB / "expectations.sh").as_posix()}"\n'
        'for e in "${EXPECTATIONS[@]}"; do echo "${e%%|*}|$(cut -d"|" -f2 <<< "$e")"; done\n'
        'applies_ssh_ladder && echo "ladder: да" || echo "ladder: нет"\n'
        'applies_monthly_updates && echo "updates: да" || echo "updates: нет"',
        EXPECT_STATE=str(tmp_path / "state"))
    assert "ssh_ladder|fix" in r.stdout and "monthly_updates|fix" in r.stdout
    assert "ladder: нет" in r.stdout and "updates: нет" in r.stdout


def test_позиции_реестра_с_отметкой_следят(tmp_path):
    (tmp_path / "state").write_text("ssh_ladder=on\nmonthly_updates=on\n")
    r = _bash(
        f'source "{(LIB / "expectations.sh").as_posix()}"\n'
        'applies_ssh_ladder && echo "ladder: да"\n'
        'applies_monthly_updates && echo "updates: да"\n'
        'want_monthly_updates',
        EXPECT_STATE=str(tmp_path / "state"))
    assert "ladder: да" in r.stdout and "updates: да" in r.stdout
    # want_ и updates_state говорят одними словами — иначе вечное расхождение.
    assert "раз в 30 дн." in r.stdout
