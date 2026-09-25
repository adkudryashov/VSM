"""
Сводка за сутки: расчёты и текст. Без ввода-вывода — прогоняется тестами целиком.

ЗАЧЕМ ОТДЕЛЬНО. Почти всё, что сервер отдаёт, — накопительные счётчики: трафик
интерфейса с загрузки, трафик пользователя telemt с запуска движка, отброшенные
фаерволом пакеты с последней перезагрузки. Сводка — это разница двух снимков, и
ошибка в разнице (перезапуск посреди суток, сброс трафика в панели) даёт либо
отрицательный трафик, либо чужие гигабайты. Такое проверяется только на
выдуманных числах, а не на живом сервере.

ПРАВИЛО ТЕКСТА (решение владельца 25.09.2026): читается за десять секунд.
Цифры, которые меняются каждый день, — всегда; всё остальное — «в порядке» одной
строкой и подробно только когда есть что сказать.
"""

from __future__ import annotations

import html
import statistics
from dataclasses import dataclass, field
from datetime import datetime, time as dtime, timedelta
from typing import Optional
from zoneinfo import ZoneInfo

DAY = 86400


# ---------------------------------------------------------------- счётчики
def delta(now: Optional[int], prev: Optional[int]) -> Optional[int]:
    """
    Прирост накопительного счётчика.

    Счётчик уменьшился — значит сбросился (перезапуск, перезагрузка, сброс
    трафика в панели), и всё, что он насчитал, набежало уже после сброса.
    Прежнего значения нет — новый пользователь: весь его счёт за этот период.
    """
    if now is None:
        return None
    if prev is None or now < prev:
        return now
    return now - prev


def per_name(now: dict, prev: dict, restarted: bool = False) -> dict:
    """Прирост по каждому имени. restarted — источник перезапускался и все
    счётчики начались с нуля: тогда прежние значения не вычитаются вовсе, иначе
    выросший после перезапуска счётчик дал бы заниженную разницу."""
    base = {} if restarted else (prev or {})
    return {k: delta(v, base.get(k)) or 0 for k, v in (now or {}).items()}


# --------------------------------------------------------------- расписание
def next_run(after: float, hhmm: str, tz: str) -> float:
    """Ближайшее hh:mm в поясе tz строго позже after."""
    zone = ZoneInfo(tz)
    h, m = (int(x) for x in hhmm.split(":", 1))
    day = datetime.fromtimestamp(after, zone).date()
    for shift in (0, 1, 2):
        cand = datetime.combine(day + timedelta(days=shift), dtime(h, m), zone)
        if cand.timestamp() > after:
            return cand.timestamp()
    raise ValueError("не нашлось следующего времени")  # недостижимо


# ------------------------------------------------------------------ формат
def num(n: int) -> str:
    """2339 → «2 339» (узкий неразрывный пробел: число не рвётся на строки)."""
    return f"{int(n):,}".replace(",", " ")


def size(b: Optional[int]) -> str:
    if b is None:
        return "—"
    if b >= 10**9:
        return f"{b / 10**9:.1f} ГБ".replace(".", ",")
    if b >= 10**6:
        return f"{round(b / 10**6)} МБ"
    if b > 0:
        return "<1 МБ"
    return "0"


def minutes(m: int) -> str:
    m = max(int(m), 0)
    if m < 60:
        return f"{m} мин"
    h, r = divmod(m, 60)
    return f"{h} ч {r} мин" if r else f"{h} ч"


def plural(n: int, one: str, few: str, many: str) -> str:
    n = abs(int(n))
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


def change(cur: Optional[int], prev: Optional[int]) -> str:
    """«↑ 12% ко вчера». Пусто, когда сравнивать не с чем."""
    if cur is None or not prev:
        return ""
    p = round((cur - prev) / prev * 100)
    if p == 0:
        return "как вчера"
    return f"{'↑' if p > 0 else '↓'} {abs(p)}% ко вчера"


def window_label(a: float, b: float) -> str:
    """«за сутки», если окно около суток; иначе честная длина."""
    span = int((b - a) / 60)
    if abs(span - 1440) <= 10:
        return "за сутки"
    return f"за {minutes(span)}"


def surge(value: Optional[int], history: list) -> str:
    """
    «⚠️ ×12», если прощупываний в разы больше обычного.

    Не абсолютный порог: он у каждого сервера свой и либо молчит, либо кричит
    каждый день. Обычное — медиана прошлых суток; меньше трёх суток истории —
    сравнивать не с чем. Пять раз и не меньше полусотни: удвоение с 3 до 6 —
    шум, а не событие.
    """
    past = [int(x) for x in (history or []) if x is not None]
    if value is None or len(past) < 3:
        return ""
    norm = statistics.median(past)
    if norm <= 0 or value < 50 or value < 5 * norm:
        return ""
    return f" ⚠️ ×{round(value / norm)}"


# ------------------------------------------------------------------ события
def overlapping(events: list, a: float, b: float) -> list:
    """События сторожа, задевшие окно [a, b]. Незакрытое длится до b."""
    out = []
    for e in events or []:
        start = float(e.get("start") or 0)
        end = e.get("end")
        end = b if end is None else float(end)
        if end >= a and start <= b:
            out.append(e)
    return out


def clipped_minutes(e: dict, a: float, b: float) -> int:
    start = max(float(e.get("start") or 0), a)
    end = e.get("end")
    end = min(b if end is None else float(end), b)
    return max(int((end - start) / 60), 0)


# ------------------------------------------------------------------- данные
@dataclass
class Facts:
    server: str
    a: float
    b: float
    tz: str = "Europe/Moscow"
    # Трафик
    traffic: Optional[int] = None
    traffic_since_boot: bool = False     # перезагрузка посреди окна: часть потеряна
    traffic_prev: Optional[int] = None
    xui: Optional[dict] = None           # email → байты; None — 3x-ui нет
    telemt: Optional[dict] = None        # пользователь → байты; None — telemt не ответил
    peak: Optional[tuple] = None         # (соединений, epoch)
    # Защита
    ssh: Optional[int] = None
    ssh_prev: Optional[int] = None
    bans: Optional[tuple] = None         # (банов, адресов, дошли до суток); None — fail2ban нет
    probes: Optional[int] = None
    probes_hist: list = field(default_factory=list)
    firewall: Optional[int] = None       # отброшено пакетов
    firewall_off: bool = False
    # Работа
    watchdog: bool = True
    events: list = field(default_factory=list)
    ru: Optional[tuple] = None           # (проверок, провальных); None — нет источника
    hub_total: Optional[int] = None      # None — хаб не подключён; -1 — не ответил
    backup: Optional[tuple] = None       # ("ok", байты) | ("missing", ошибка: bool); None — нет таймера
    # Обслуживание: готовые строки, только про то, что требует действия
    maint: list = field(default_factory=list)


_DC_KINDS = {"dc_dead"}
_HUB_KINDS = {"beszel_silent", "beszel_hub"}


def _named(items: dict) -> str:
    return " · ".join(f"{html.escape(str(k))} {size(v)}" for k, v in items.items())


def render(f: Facts) -> str:
    zone = ZoneInfo(f.tz)
    end = datetime.fromtimestamp(f.b, zone)
    lines = [f"📊 <b>{html.escape(f.server)}</b> · {end:%d.%m %H:%M}, {window_label(f.a, f.b)}", ""]

    # --- Трафик
    head = f"📶 <b>Трафик</b>  {'≈ ' if f.traffic_since_boot else ''}{size(f.traffic)}"
    ch = change(f.traffic, f.traffic_prev) if not f.traffic_since_boot else ""
    lines.append(head + (f"  {ch}" if ch else ""))
    if f.traffic_since_boot:
        lines.append("   <i>сервер перезагружался — счёт с загрузки</i>")
    if f.xui is not None:
        lines.append(f"   3x-ui: {_named(f.xui) or 'клиентов нет'}")
    if f.telemt is not None:
        lines.append(f"   telemt: {_named(f.telemt) or 'пользователей нет'}")
    else:
        lines.append("   telemt: ⚠️ не ответил")
    if f.peak and f.peak[0]:
        at = datetime.fromtimestamp(f.peak[1], zone)
        lines.append(f"   Пик: {num(f.peak[0])} {plural(f.peak[0], 'подключение', 'подключения', 'подключений')} в {at:%H:%M}")
    lines.append("")

    # --- Защита
    lines.append("🛡 <b>Защита</b>")
    if f.ssh is not None:
        ch = change(f.ssh, f.ssh_prev)
        lines.append(f"   SSH: {num(f.ssh)} {plural(f.ssh, 'попытка', 'попытки', 'попыток')} подбора"
                     + (f" · {ch}" if ch else ""))
    if f.bans is None:
        lines.append("   Баны: ⚠️ fail2ban не установлен")
    else:
        n, ips, long = f.bans
        s = f"   Баны: {num(n)}"
        if n:
            s += f" · {num(ips)} {plural(ips, 'адрес', 'адреса', 'адресов')}"
            if long:
                s += f" · до суток и дольше: {num(long)}"
        lines.append(s)
    if f.probes is not None:
        lines.append(f"   Прощупывание прокси: {num(f.probes)}{surge(f.probes, f.probes_hist)}")
    if f.firewall_off:
        lines.append("   Фаервол: ⚠️ выключен")
    elif f.firewall is not None:
        lines.append(f"   Фаервол: {num(f.firewall)} отброшено")
    lines.append("")

    # --- Работа
    lines.append("🩺 <b>Работа</b>")
    evs = overlapping(f.events, f.a, f.b)
    if not f.watchdog:
        lines.append("   Сторож: выключен")
    elif not evs:
        lines.append("   Сторож: тревог нет")
    else:
        total = sum(clipped_minutes(e, f.a, f.b) for e in evs)
        lines.append(f"   Сторож: ⚠️ {len(evs)} {plural(len(evs), 'тревога', 'тревоги', 'тревог')}"
                     + (f" · {minutes(total)}" if total else ""))
    if f.ru is not None:
        n, bad = f.ru
        if n == 0:
            lines.append("   Россия: ⚠️ проверок не было")
        elif bad:
            lines.append(f"   Россия: ⚠️ недоступен {bad} из {n}")
        else:
            lines.append(f"   Россия: доступен · {num(n)} {plural(n, 'проверка', 'проверки', 'проверок')}")
    dc = [e for e in evs if e.get("kind") in _DC_KINDS]
    if f.watchdog:
        if dc:
            lines.append("   Telegram: ⚠️ " + "; ".join(
                f"DC {html.escape(e.get('detail') or '?')} пропадал {minutes(clipped_minutes(e, f.a, f.b))}"
                for e in dc))
        else:
            lines.append("   Telegram: все DC на связи")
    if f.hub_total is not None:
        hub = [e for e in evs if e.get("kind") in _HUB_KINDS]
        if f.hub_total < 0 and not hub:
            lines.append("   Серверы: ⚠️ хаб не ответил")
        elif not hub:
            lines.append(f"   Серверы: все {f.hub_total} на связи")
        else:
            parts = []
            for e in hub:
                m = minutes(clipped_minutes(e, f.a, f.b))
                if e.get("kind") == "beszel_hub":
                    parts.append(f"хаб не отвечал {m}")
                else:
                    who = e.get("detail") or "сервер"
                    verb = "недоступны" if "," in who else "недоступен"
                    parts.append(f"{html.escape(who)} {verb} {m}")
            lines.append("   Серверы: ⚠️ " + "; ".join(parts))
    if f.backup is not None:
        if f.backup[0] == "ok":
            lines.append(f"   Копия: сделана · {size(f.backup[1]) if f.backup[1] >= 10**6 else str(round(f.backup[1] / 1024)) + ' КБ'}")
        else:
            lines.append("   Копия: ⚠️ не сделана" + (" — ошибка" if f.backup[1] else ""))
    lines.append("")

    # --- Обслуживание
    if f.maint:
        lines.append("🔧 <b>Обслуживание</b>")
        lines += [f"   {m}" for m in f.maint]
    else:
        lines.append("✅ Обслуживание не требуется")
    return "\n".join(lines)
