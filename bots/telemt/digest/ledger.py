"""
Состояние сводки: снимок счётчиков на начало суток, события сторожа, пик
подключений и выключатель рассылки. Живёт в data/digest.json и переживает
перезапуск бота — иначе после планового недельного перезапуска сводка
считала бы сутки с момента старта.

ОДИН ОБЪЕКТ НА ПРОЦЕСС. Пишут в него двое: сторож (события) и цикл сводки
(снимки, пик). Если бы каждый читал файл, правил и писал обратно, запись
сторожа, сделанная, пока сводка собиралась, пропадала бы при её сохранении.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Optional

from config import DATA_DIR, settings

PATH = Path(DATA_DIR) / "digest.json"
# События храним с запасом на неделю: сводку могли не отправить несколько
# дней (бот стоял), а окно тогда длиннее суток.
KEEP_EVENTS = 8 * 86400
KEEP_PROBES = 7

# Позиции сторожа → вид события в сводке. Имена — поля WatchState.
_FLAPS = ("engine", "writers", "dc_dead", "ru_access", "ru_stale", "beszel_hub",
          "beszel_silent", "hard_fails", "dns", "clock_skew", "kdf", "web_down",
          "web_full")


class Ledger:
    def __init__(self, path: Path = PATH):
        self.path = path
        self.data: dict = {}
        self._load()

    # ------------------------------------------------------------ хранение
    def _load(self) -> None:
        try:
            self.data = json.loads(self.path.read_text(encoding="utf-8")) or {}
        except FileNotFoundError:
            self.data = {}
        except Exception as exc:
            logging.warning("Сводка: не прочитал %s (%s) — начинаю заново", self.path, exc)
            self.data = {}

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.path)
        except Exception as exc:
            logging.warning("Сводка: не сохранил состояние: %s", exc)

    # ---------------------------------------------------------- выключатель
    @property
    def enabled(self) -> bool:
        """Решение из бота важнее умолчания из .env: кнопку нажали — значит так."""
        v = self.data.get("enabled")
        return settings.DIGEST_ENABLED if v is None else bool(v)

    def set_enabled(self, on: bool) -> None:
        self.data["enabled"] = bool(on)
        self.save()

    # -------------------------------------------------------------- события
    def record(self, kind: str, event: str, since: Optional[float],
               detail: str = "", now: Optional[float] = None) -> None:
        """
        Тревога сторожа поднялась (FIRE) или снялась (CLEAR).

        Начало — первый плохой опрос, а не момент тревоги: так же считает сам
        сторож, и длительность в сводке совпадёт с той, что пришла в отбое.
        """
        now = time.time() if now is None else now
        evs = self.data.setdefault("events", [])
        if event == "fire":
            evs.append({"kind": kind, "start": float(since or now), "end": None,
                        "detail": detail})
        elif event == "clear":
            for e in reversed(evs):
                if e.get("kind") == kind and e.get("end") is None:
                    e["end"] = now
                    break
        cutoff = now - KEEP_EVENTS
        self.data["events"] = [e for e in evs
                               if e.get("end") is None or float(e["end"]) >= cutoff]
        self.save()

    # ---------------------------------------------------------------- пик
    def note_peak(self, value: int, now: Optional[float] = None) -> bool:
        """Запомнить, если больше прежнего пика. True — изменилось."""
        now = time.time() if now is None else now
        peak = self.data.get("peak") or {}
        if value > int(peak.get("value") or 0):
            self.data["peak"] = {"value": int(value), "at": now}
            return True
        return False

    # -------------------------------------------------------------- сутки
    def roll(self, now: float, snap: dict, traffic: Optional[int],
             ssh: Optional[int], probes: Optional[int]) -> None:
        """Закрыть сутки: новый снимок, прошлые итоги для «ко вчера», пик с нуля."""
        # Начало закрываемых суток — ДО перезаписи: иначе длина окна всегда ноль.
        last = self.data.get("last_run")
        self.data["last_run"] = now
        self.data["snap"] = snap
        self.data["prev"] = {"traffic": traffic, "ssh": ssh,
                             "span": (now - float(last)) if last else None}
        hist = list(self.data.get("probes_hist") or [])
        if probes is not None:
            hist.append(int(probes))
        self.data["probes_hist"] = hist[-KEEP_PROBES:]
        self.data["peak"] = {}
        self.save()


_shared: Optional[Ledger] = None


def shared() -> Ledger:
    global _shared
    if _shared is None:
        _shared = Ledger()
    return _shared


def flap_name(state, flap) -> str:
    """Имя позиции сторожа по самому объекту: у _fire_or_clear его нет."""
    for name in _FLAPS:
        if getattr(state, name, None) is flap:
            return name
    return "other"
