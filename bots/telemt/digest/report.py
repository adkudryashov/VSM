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


# Короче этого отрезок не сравниваем: за час-другой трафик и подбор пароля
# скачут в разы без всякой причины.
MIN_COMPARE_SPAN = 3 * 3600


def change(cur: Optional[int], prev: Optional[int],
           span: Optional[float] = None, prev_span: Optional[float] = None) -> str:
    """
    «↑ 12% ко вчера» — по СКОРОСТИ (в час), а не по сумме. Пусто, когда
    сравнивать не с чем.

    Первая редакция сравнивала суммы, и нажатие «За сутки» в 22:22 показало
    «↓ 41%» и «↑ 267%»: 21 минуту сравнили с 17 минутами. Днём было бы то же
    самое — полсуток против суток дают «−50%» на ровном месте. Длина
    прошлого окна неизвестна (состояние от прежней версии) — не сравниваем.
    """
    if cur is None or not prev or not span or not prev_span:
        return ""
    if min(span, prev_span) < MIN_COMPARE_SPAN:
        return ""
    now_rate, prev_rate = cur / span, prev / prev_span
    p = round((now_rate - prev_rate) / prev_rate * 100)
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
    # Трафик. Главное число — клиенты: сетевая карта считает и то, что сервер
    # делает сам (тест скорости 26.09 дал 30 ГБ при 3,5 ГБ у клиентов).
    traffic: Optional[int] = None        # вся сеть сервера, приём + отдача
    traffic_since_boot: bool = False     # перезагрузка посреди окна: часть потеряна
    clients_prev: Optional[int] = None   # клиенты за прошлые сутки
    telemt_restarted: bool = False       # движок перезапускался: его счёт неполный
    xui: Optional[dict] = None           # email → байты; None — 3x-ui нет
    telemt: Optional[dict] = None        # пользователь → байты; None — telemt не ответил
    peak: Optional[tuple] = None         # (соединений, epoch)
    # Защита
    ssh: Optional[int] = None
    ssh_prev: Optional[int] = None
    prev_span: Optional[float] = None    # длина прошлого окна, сек; None — неизвестна
    bans: Optional[tuple] = None         # (банов, адресов, дошли до суток); None — fail2ban нет
    probes: Optional[int] = None         # чужие: наши проверки уже вычтены
    probes_ours: Optional[int] = None    # зонды MTProxyL за окно; None — не знаем
    probes_hist: list = field(default_factory=list)
    firewall: Optional[int] = None       # отброшено пакетов
    firewall_off: bool = False
    # Работа
    watchdog: bool = True
    events: list = field(default_factory=list)
    ru: Optional[tuple] = None           # (проверок, провальных); None — нет источника
    hub_total: Optional[int] = None      # None — хаб не подключён; -1 — не ответил
    # ("ok", байты) | ("pending",) — копий ещё не было, таймер новый |
    # ("missing", ошибка: bool); None — копии VSM не настроены
    backup: Optional[tuple] = None
    # Обслуживание: готовые строки, только про то, что требует действия
    maint: list = field(default_factory=list)


_DC_KINDS = {"dc_dead"}
_HUB_KINDS = {"beszel_silent", "beszel_hub"}


def _icons():
    """Значки состояния — из общего словаря бота (telemt/handlers/aboutall.py):
    три азбуки статусов в одном боте уже разводили однажды. Ввозим внутри
    функции, как экран «Серверы»: расчётам обработчики ни к чему."""
    from telemt.handlers.aboutall import BAD, OK, WARN
    return OK, WARN, BAD


def _kb(b: int) -> str:
    return size(b) if b >= 10**6 else f"{round(b / 1024)} КБ"


# ---------------------------------------------------------------- строки
# Одни и те же строки идут и в таблицы Rich Message, и в запасной текст:
# собрать их дважды значило бы однажды получить два разных вердикта об одном.

def clients_total(f: Facts) -> Optional[int]:
    """Сумма по клиентам 3x-ui и telemt; None — ни того, ни другого нет."""
    if f.xui is None and f.telemt is None:
        return None
    return sum((f.xui or {}).values()) + sum((f.telemt or {}).values())


# Прокси пропускает каждый байт клиента дважды — принял снаружи, отдал
# клиенту. Сверх двойного объёма и гигабайта сверху — работа самого сервера.
SELF_TRAFFIC_SLACK = 10**9


def _traffic(f: Facts) -> dict:
    zone = ZoneInfo(f.tz)
    clients = clients_total(f)
    names = list(dict.fromkeys(list((f.xui or {}).keys()) + list((f.telemt or {}).keys())))
    rows = [(n, (f.xui or {}).get(n), (f.telemt or {}).get(n)) for n in names]
    peak = ""
    if f.peak and f.peak[0]:
        at = datetime.fromtimestamp(f.peak[1], zone)
        peak = (f"Пик: {num(f.peak[0])} "
                f"{plural(f.peak[0], 'подключение', 'подключения', 'подключений')} в {at:%H:%M}")
    notes = []
    if clients is None:
        # Ни 3x-ui, ни telemt: остаётся только сетевая карта. Сравнивать не с
        # чем — «вчера» хранится по клиентам.
        total = ("≈ " if f.traffic_since_boot else "") + size(f.traffic)
        ch = ""
        if f.traffic_since_boot:
            notes.append("Сервер перезагружался — трафик считан с загрузки.")
    else:
        total = ("≈ " if f.telemt_restarted else "") + size(clients)
        ch = "" if f.telemt_restarted else change(clients, f.clients_prev, f.b - f.a, f.prev_span)
        if f.telemt_restarted:
            notes.append("telemt перезапускался — его трафик считан с перезапуска.")
        if f.traffic is not None and f.traffic > 2 * clients + SELF_TRAFFIC_SLACK:
            notes.append(f"Через сеть сервера прошло {size(f.traffic)}"
                         + (" с загрузки" if f.traffic_since_boot else "")
                         + ": сверх клиентов — сам сервер (тесты скорости, обновления).")
    return {"total": total, "change": ch, "notes": notes,
            "rows": rows, "has_xui": f.xui is not None, "has_telemt": f.telemt is not None,
            "peak": peak}


def _security(f: Facts) -> list:
    """(показатель, число, заметка) — заметка: сравнение со вчера или всплеск."""
    rows = []
    if f.ssh is not None:
        rows.append(("Попытки подбора SSH", num(f.ssh), change(f.ssh, f.ssh_prev, f.b - f.a, f.prev_span)))
    if f.bans is None:
        rows.append(("Баны", "—", "⚠️ fail2ban не установлен"))
    else:
        n, ips, long = f.bans
        rows.append(("Баны", num(n), f"{num(ips)} {plural(ips, 'адрес', 'адреса', 'адресов')}" if n else ""))
        if long:
            rows.append(("Баны на сутки и дольше", num(long), ""))
    if f.probes is not None:
        note = surge(f.probes, f.probes_hist).strip()
        if f.probes_ours:
            note = "; ".join(x for x in (note, f"без наших проверок ({num(f.probes_ours)})") if x)
        rows.append(("Прощупывание прокси", num(f.probes), note))
    if f.firewall_off:
        rows.append(("Фаервол", "—", "⚠️ выключен"))
    elif f.firewall is not None:
        rows.append(("Отброшено фаерволом", num(f.firewall), ""))
    return rows


def _work(f: Facts) -> list:
    """(значок, что, состояние)."""
    OK, WARN, BAD = _icons()
    rows = []
    evs = overlapping(f.events, f.a, f.b)
    if not f.watchdog:
        rows.append((WARN, "Сторож", "выключен"))
    elif not evs:
        rows.append((OK, "Сторож", "тревог нет"))
    else:
        total = sum(clipped_minutes(e, f.a, f.b) for e in evs)
        still = any(e.get("end") is None for e in evs)
        rows.append((BAD if still else WARN, "Сторож",
                     f"{len(evs)} {plural(len(evs), 'тревога', 'тревоги', 'тревог')}"
                     + (f" · {minutes(total)}" if total else "")
                     + (" · идёт сейчас" if still else "")))
    if f.ru is not None:
        n, bad = f.ru
        if n == 0:
            rows.append((WARN, "Россия", "проверок не было"))
        elif bad:
            rows.append((BAD if bad == n else WARN, "Россия", f"недоступен {bad} из {n}"))
        else:
            rows.append((OK, "Россия", f"доступен · {num(n)} {plural(n, 'проверка', 'проверки', 'проверок')}"))
    if f.watchdog:
        dc = [e for e in evs if e.get("kind") in _DC_KINDS]
        if dc:
            rows.append((WARN, "Telegram", "; ".join(
                f"DC {html.escape(e.get('detail') or '?')} пропадал {minutes(clipped_minutes(e, f.a, f.b))}"
                for e in dc)))
        else:
            rows.append((OK, "Telegram", "все DC на связи"))
    if f.hub_total is not None:
        hub = [e for e in evs if e.get("kind") in _HUB_KINDS]
        if f.hub_total < 0 and not hub:
            rows.append((BAD, "Серверы", "хаб не ответил"))
        elif not hub:
            rows.append((OK, "Серверы", f"все {f.hub_total} на связи"))
        else:
            parts = []
            for e in hub:
                m = minutes(clipped_minutes(e, f.a, f.b))
                if e.get("kind") == "beszel_hub":
                    parts.append(f"хаб не отвечал {m}")
                else:
                    who = e.get("detail") or "сервер"
                    parts.append(f"{html.escape(who)} {'недоступны' if ',' in who else 'недоступен'} {m}")
            rows.append((WARN, "Серверы", "; ".join(parts)))
    if f.backup is not None:
        kind = f.backup[0]
        if kind == "ok":
            rows.append((OK, "Копия", f"сделана · {_kb(f.backup[1])}"))
        elif kind == "pending":
            rows.append((OK, "Копия", "первая ещё впереди"))
        else:
            rows.append((BAD if f.backup[1] else WARN, "Копия",
                         "не сделана" + (" — ошибка" if f.backup[1] else "")))
    return rows


def _maint(f: Facts) -> list:
    """(значок, текст). Строки источника с «⚠️» требуют действия, остальные — к сведению."""
    OK, WARN, _ = _icons()
    out = []
    for m in f.maint:
        if m.startswith("⚠️"):
            out.append((WARN, m.removeprefix("⚠️").strip()))
        else:
            out.append(("ℹ️", m))
    return out


def _title(f: Facts) -> tuple:
    end = datetime.fromtimestamp(f.b, ZoneInfo(f.tz))
    return html.escape(f.server), f"{end:%d.%m %H:%M} · {window_label(f.a, f.b)}"


# ---------------------------------------------------------------- вывод
def render_rich(f: Facts) -> str:
    """Rich Message: заголовки и таблицы, как «Сводка» и «Серверы» в этом боте."""
    name, when = _title(f)
    t = _traffic(f)
    out = [f"<h2>📊 {name}</h2>", f"<p><i>{when}</i></p>"]

    out.append(f"<h3>📶 Трафик · {t['total']}" + (f" · {t['change']}" if t["change"] else "") + "</h3>")
    for n in t["notes"]:
        out.append(f"<p><i>{n}</i></p>")
    if t["rows"]:
        head = "<tr><th>Клиент</th>" + ("<th>3x-ui</th>" if t["has_xui"] else "") \
               + ("<th>telemt</th>" if t["has_telemt"] else "") + "</tr>"
        body = "".join(
            f"<tr><td>{html.escape(str(n))}</td>"
            + (f"<td>{size(x) if x is not None else '—'}</td>" if t["has_xui"] else "")
            + (f"<td>{size(y) if y is not None else '—'}</td>" if t["has_telemt"] else "")
            + "</tr>" for n, x, y in t["rows"])
        out.append(f"<table>{head}{body}</table>")
    if not t["has_telemt"]:
        out.append("<p>⚠️ telemt не ответил</p>")
    if t["peak"]:
        out.append(f"<p>{t['peak']}</p>")

    out.append("<h3>🛡 Защита</h3>")
    out.append("<table><tr><th>Показатель</th><th>Число</th><th>Заметка</th></tr>" + "".join(
        f"<tr><td>{a}</td><td>{b}</td><td>{c}</td></tr>" for a, b, c in _security(f)) + "</table>")

    out.append("<h3>🩺 Работа</h3>")
    out.append("<table><tr><th>Что</th><th>Состояние</th></tr>" + "".join(
        f"<tr><td>{i} {a}</td><td>{b}</td></tr>" for i, a, b in _work(f)) + "</table>")

    m = _maint(f)
    if m:
        out.append("<h3>🔧 Обслуживание</h3>")
        out.append("<table>" + "".join(f"<tr><td>{i} {s}</td></tr>" for i, s in m) + "</table>")
    else:
        out.append(f"<p>{_icons()[0]} Обслуживание не требуется</p>")
    return "".join(out)


def render(f: Facts) -> str:
    """Запасной текст — на случай, если Rich Message не примут. Те же строки."""
    name, when = _title(f)
    t = _traffic(f)
    lines = [f"📊 <b>{name}</b> · {when}", ""]
    lines.append(f"📶 <b>Трафик</b>  {t['total']}" + (f"  {t['change']}" if t["change"] else ""))
    for n in t["notes"]:
        lines.append(f"   <i>{n}</i>")
    for n, x, y in t["rows"]:
        parts = []
        if t["has_xui"] and x is not None:
            parts.append(f"3x-ui {size(x)}")
        if t["has_telemt"] and y is not None:
            parts.append(f"telemt {size(y)}")
        lines.append(f"   {html.escape(str(n))}: " + " · ".join(parts))
    if not t["has_telemt"]:
        lines.append("   telemt: ⚠️ не ответил")
    if t["peak"]:
        lines.append(f"   {t['peak']}")
    lines += ["", "🛡 <b>Защита</b>"]
    for a, b, c in _security(f):
        lines.append(f"   {a}: {b}" + (f" · {c}" if c else ""))
    lines += ["", "🩺 <b>Работа</b>"]
    for i, a, b in _work(f):
        lines.append(f"   {i} {a}: {b}")
    lines.append("")
    m = _maint(f)
    if m:
        lines.append("🔧 <b>Обслуживание</b>")
        lines += [f"   {i} {s}" for i, s in m]
    else:
        lines.append(f"{_icons()[0]} Обслуживание не требуется")
    return "\n".join(lines)
