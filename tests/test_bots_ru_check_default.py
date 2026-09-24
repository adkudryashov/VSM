"""
Проверка доступности из России включается сама, если стоит MTProxyL.

ЗАЧЕМ. Умолчание «выключено» бережёт квоту Globalping и не шлёт к
маскирующемуся серверу чужой трафик — но с MTProxyL бот только читает его
готовый вердикт. Прогон с нуля 24.09.2026: всё стояло, проверка молчала, пока
владелец не включил её руками. Источник при этом обязан быть mtproxyl, а не
auto: сразу после установки MTProxyL вердикта ещё нет, и auto пошёл бы мерить
своими зондами — ровно то, чего умолчание избегало.

Блок вырезается из установщика и гоняется в bash отдельно: весь stacks/bots.sh
ставит пакеты и службы, запускать его в тесте нельзя.
"""
import shutil
import subprocess

import pytest
from pathlib import Path

УСТАНОВЩИК = Path(__file__).resolve().parent.parent / "stacks" / "bots.sh"
НАЧАЛО = 'RU_CHECK_ENABLED="${RU_CHECK_ENABLED:-$(conf_get RU_CHECK_ENABLED)}"'
КОНЕЦ = 'RU_CHECK_SOURCE="${RU_CHECK_SOURCE:-auto}"'


def _блок():
    строки = УСТАНОВЩИК.read_text(encoding="utf-8").splitlines()
    i = строки.index(НАЧАЛО)
    j = строки.index(КОНЕЦ)
    assert i < j
    return "\n".join(строки[i:j + 1])


def _прогон(tmp_path, *, mtproxyl, conf):
    скрипт = tmp_path / "mtproxyl.sh"
    if mtproxyl:
        скрипт.write_text("")
    # conf_get — заглушка: отдаёт значения «из bots.conf» прошлой установки.
    заглушка = "conf_get() { case \"$1\" in %s *) ;; esac; }" % "".join(
        f'{k}) echo "{v}" ;; ' for k, v in conf.items())
    код = "\n".join([
        заглушка,
        f'MTPROXYL_SCRIPT="{скрипт}"',
        "unset RU_CHECK_ENABLED RU_CHECK_SOURCE",
        _блок(),
        'echo "$RU_CHECK_ENABLED $RU_CHECK_SOURCE"',
    ])
    r = subprocess.run(["bash", "-c", код], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="нужен bash")


def test_mtproxyl_есть_выбора_не_было(tmp_path):
    assert _прогон(tmp_path, mtproxyl=True, conf={}) == "true mtproxyl"


def test_mtproxyl_нет(tmp_path):
    assert _прогон(tmp_path, mtproxyl=False, conf={}) == "false auto"


def test_выбор_владельца_не_перебивается(tmp_path):
    """Выключил сам — установщик не включает обратно."""
    assert _прогон(tmp_path, mtproxyl=True,
                   conf={"RU_CHECK_ENABLED": "false"}) == "false auto"


def test_свои_зонды_не_перебиваются(tmp_path):
    """Выбрал мерить сам — источник остаётся self."""
    assert _прогон(tmp_path, mtproxyl=True,
                   conf={"RU_CHECK_SOURCE": "self"}) == "false self"
