"""
Перезапуск движка сторожем — сам и по кнопке в тревоге.

ОТКУДА. 28.09.2026 на главном писателей не было 12 часов: 0 из 43, движок
каждые пару секунд пытался их поднять и не мог, хотя TCP до серверов Telegram
проходил. Внутренняя замена пула висела 2,5 часа. Перезапуск движка вернул 42
из 43 писателей за 20 секунд. Сторож всё это время только писал.

КОГДА САМ — все условия сразу:

1. Писателей почти нет (покрытие ниже WATCHDOG_RESTART_BELOW_PCT) дольше
   WATCHDOG_RESTART_AFTER_MINUTES. Порог не тот, что у тревоги (50%): просадку
   до 40% даёт и закрытый снаружи дата-центр, её перезапуск не лечит. А после
   каждого перезапуска писателей нет 10–20 секунд — их сторож не должен
   принимать за аварию, отсюда время.
2. Серверы Telegram отвечают на TCP с этого сервера — хотя бы половина точек
   из ответа движка. Путь закрыт снаружи (так было с DC5 в сентябре) —
   перезапуск не поможет, а клиентов оборвёт зря. Тогда сторож только пишет.
3. Не чаще раза в WATCHDOG_RESTART_COOLDOWN_HOURS, считая и нажатия кнопки.
   Не помог — сторож говорит об этом и больше не пробует: иначе вышел бы цикл,
   который раз за разом обрывает клиентов, ничего не чиня.

ОДИН СЛУЧАЙ — ЕЩЁ НЕ ЗАКОН. Перезапуск помог один раз. Поэтому пункт 3 и
выключатель WATCHDOG_AUTO_RESTART, а кнопка в тревоге оставляет решение
человеку, когда автоматика выключена или ещё не дождалась своих 30 минут.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Optional

# Что решил сторож на этом опросе.
DUE = "due"            # пора перезапускать (если путь открыт)
COOLDOWN = "cooldown"  # пора бы, но недавно уже перезапускали

# Сколько ждать после перезапуска, прежде чем сказать «не помог». Писатели
# поднимаются за 20 секунд; десять минут — с большим запасом на медленный пул.
VERDICT_AFTER = 10 * 60
# Перезапуск, случившийся чуть раньше начала аварии, — её часть: ручной
# перезапуск при 40% сам роняет покрытие в ноль, и авария «начинается» после.
LEAD = 5 * 60


def due(*, enabled: bool, stuck_since: Optional[float], now: float,
        last_restart: float, after: float, cooldown: float) -> Optional[str]:
    """Пора ли перезапускать. None — нет (выключено, рано, писатели есть)."""
    if not enabled or stuck_since is None:
        return None
    if now - stuck_since < after:
        return None
    if last_restart and now - last_restart < cooldown:
        return COOLDOWN
    return DUE


def restarted_in_incident(stuck_since: Optional[float], last_restart: float) -> bool:
    """Был ли перезапуск в этой аварии (или сразу перед ней)."""
    if stuck_since is None or not last_restart:
        return False
    return last_restart >= stuck_since - LEAD


def endpoints(dc_payload) -> list:
    """(адрес, порт) точек Telegram из /v1/stats/dcs. Непонятное пропускаем."""
    out = []
    try:
        groups = (dc_payload.get("data") or dc_payload).get("dcs") or []
    except AttributeError:
        return out
    for group in groups:
        if not isinstance(group, dict):
            continue
        for raw in group.get("endpoints") or []:
            host, sep, port = str(raw).rpartition(":")
            if not sep or not port.isdigit():
                continue
            host = host.strip("[]")
            if host and (host, int(port)) not in out:
                out.append((host, int(port)))
    return out


async def _reachable(host: str, port: int, timeout: float) -> bool:
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except Exception:
        return False
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass
    return True


async def path_open(points: list, timeout: float = 3.0, limit: int = 8) -> Optional[bool]:
    """
    Отвечают ли серверы Telegram. None — спросить некого (точек нет).

    Только TCP-рукопожатие, без данных: этого хватает, чтобы отличить закрытый
    снаружи путь от застрявшего движка — 28.09 рукопожатие проходило, а
    писателей не было. Половина, а не все: пара точек бывает недоступна и на
    исправном сервере.
    """
    if not points:
        return None
    sample = points[:limit]
    results = await asyncio.gather(*(_reachable(h, p, timeout) for h, p in sample))
    return sum(results) * 2 >= len(sample)


async def systemctl_restart(unit: str = "telemt", timeout: float = 90) -> tuple[bool, str]:
    """(удалось, текст ошибки). Бот работает от root — sudo не нужен."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "systemctl", "restart", unit,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        _, err = await asyncio.wait_for(proc.communicate(), timeout)
    except Exception as exc:
        logging.warning("Сторож: перезапуск %s не удался: %s", unit, exc)
        return False, str(exc)
    text = (err or b"").decode(errors="replace").strip()
    return proc.returncode == 0, text[-300:]
