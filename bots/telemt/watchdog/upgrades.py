"""
Не система ли обновилась только что.

ЗАЧЕМ. Сторож честно сообщает «Движок перезапустился», но не говорит почему,
и владелец два дня подряд гадал. Разбор 03.09.2026 показал причину: раз в
сутки apt-daily-upgrade.timer запускает unattended-upgrades, а needrestart
перезапускает службы, слинкованные с обновлёнными библиотеками. libpam и
libgcrypt слинкованы почти со всем, поэтому перезапускается и движок, и сам
бот следом.

Это не авария: без перезапуска процесс продолжал бы работать со старой
уязвимой библиотекой в памяти. Но молчать о причине — значит заставлять
человека каждый раз выяснять её заново.

ЧИТАЕМ ЧУЖОЙ ФАЙЛ. /var/log/apt/history.log принадлежит apt, и его формат
может измениться. Поэтому любая неудача разбора означает «не знаю», а не
ошибку: подсказка исчезнет, само сообщение останется.
"""

import logging
import re
from datetime import datetime
from pathlib import Path

APT_HISTORY = Path("/var/log/apt/history.log")

# Блок в history.log выглядит так:
#   Start-Date: 2026-09-03  06:23:10
#   Commandline: /usr/bin/unattended-upgrade
#   Upgrade: libpam-runtime:amd64 (1.7.0-5ubuntu3.1, 1.7.0-5ubuntu3.2), ...
_START = re.compile(r"^Start-Date:\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})")
_PKG = re.compile(r"([A-Za-z0-9][A-Za-z0-9+.-]*)(?::[A-Za-z0-9_-]+)?\s*\(")


def _blocks(text: str):
    """Разбивает журнал на блоки по Start-Date."""
    block: list[str] = []
    for line in text.splitlines():
        if line.startswith("Start-Date:") and block:
            yield block
            block = []
        block.append(line)
    if block:
        yield block


def recent_packages(within_secs: int = 900, path: Path = APT_HISTORY,
                    now: float | None = None, limit: int = 4) -> list[str]:
    """
    Пакеты, обновлённые автоматикой за последние within_secs секунд.

    Пустой список — «не знаю»: файла нет, не прочитался, формат не тот или
    обновлений не было. Все четыре случая для нас одинаковы.

    Окно 15 минут по умолчанию, а не минута: needrestart перезапускает службы
    ПОСЛЕ распаковки, и между записью в журнал apt и перезапуском проходит
    заметное время. Замер 03.09.2026: обновление в 06:23:10, движок поднялся
    в 06:23:17, но в тот же заход apt ставил пакеты до 06:23:19.
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return []
    except Exception as exc:
        logging.info("Сторож: не прочитал %s: %s", path, exc)
        return []

    now = datetime.now().timestamp() if now is None else now
    found: list[str] = []

    for block in _blocks(text):
        head = _START.match(block[0]) if block else None
        if not head:
            continue
        try:
            stamp = datetime.strptime(f"{head.group(1)} {head.group(2)}",
                                      "%Y-%m-%d %H:%M:%S").timestamp()
        except ValueError:
            continue
        if not 0 <= now - stamp <= within_secs:
            continue
        # Только автоматика. Своё «apt install» причиной не называем: если
        # человек ставил пакеты руками, он и так знает, что сделал.
        if not any(l.startswith("Commandline:") and "unattended-upgrade" in l
                   for l in block):
            continue
        for line in block:
            if line.startswith(("Upgrade:", "Install:")):
                for name in _PKG.findall(line):
                    if name not in found:
                        found.append(name)

    return found[:limit]
