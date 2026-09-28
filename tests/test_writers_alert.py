"""
Тревоги о писателях и о дата-центрах без них — после аварии 28.09.2026.

ЧТО СЛУЧИЛОСЬ. На главном сервере писателей не было 12 часов (0 из 43), а
Telegram у клиентов работал: движок сам пускал их напрямую (me2dc_fallback).
Сторож при этом соврал трижды:
  1. каждые полчаса «клиенты будут подключаться и зависать»;
  2. «✅ дата-центры снова с писателями», когда опустела последняя группа;
  3. «общее покрытие остаётся выше порога» при покрытии 0%.

У каждой правки есть обратная сторона: без запасного пути и когда о нём
ничего не известно, тревога обязана говорить и повторять по-прежнему.
Ответы движка — формы, снятые с главного 28.09.2026 (telemt 3.5.8).
"""
import asyncio
import time

import pytest

from config import settings
from telemt.watchdog import monitor
from telemt.watchdog.incidents import WatchState


def писатели(alive, required=43):
    pct = alive / required * 100
    return {"summary": {"required_writers": required, "alive_writers": alive,
                        "coverage_pct": pct, "fresh_alive_writers": alive,
                        "fresh_coverage_pct": pct}, "writers": []}


def ворота(fallback=True):
    return {"ok": True, "data": {"accepting_new_connections": True,
                                 "me2dc_fallback_enabled": fallback,
                                 "use_middle_proxy": True, "route_mode": "middle"}}


ГРУППЫ = (-1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -203, 203)


def группы(живые: dict):
    """Ответ /v1/stats/dcs: у перечисленных групп столько писателей, у прочих ноль."""
    return {"ok": True, "data": {"dcs": [
        {"dc": dc, "alive_writers": живые.get(dc, 0), "required_writers": 3,
         "coverage_pct": min(живые.get(dc, 0) / 3 * 100, 100.0)}
        for dc in ГРУППЫ]}}


ВСЕ_ЖИВЫ = {dc: 3 for dc in ГРУППЫ}


class Бот:
    def __init__(self):
        self.sent: list[str] = []

        self.markups: list = []

    async def send_message(self, chat_id, text, parse_mode=None, reply_markup=None):
        self.sent.append(text)
        self.markups.append(reply_markup)


class API:
    def __init__(self):
        self.gates = ворота(True)
        self.groups = группы(ВСЕ_ЖИВЫ)

    async def runtime_gates(self):
        if isinstance(self.gates, Exception):
            raise self.gates
        return self.gates

    async def dcs(self):
        return self.groups


class Часы:
    def __init__(self):
        self.now = 1_790_000_000.0

    def __call__(self):
        return self.now


@pytest.fixture
def часы(monkeypatch):
    c = Часы()
    monkeypatch.setattr(time, "time", c)
    return c


@pytest.fixture
def сторож(monkeypatch, часы):
    monkeypatch.setattr(monitor, "_save_state", lambda state: None)
    monkeypatch.setattr(settings, "ADMIN_IDS", [1])
    monkeypatch.setattr(settings, "WATCHDOG_COVERAGE_FLOOR_PCT", 50)
    # Автоперезапуск проверяется в test_watchdog_restart.py. Здесь он выключен,
    # а настоящий systemctl подменён отказом — на случай, если его всё же позовут.
    monkeypatch.setattr(settings, "WATCHDOG_AUTO_RESTART", False)

    async def нельзя(*a, **k):
        raise AssertionError("тест позвал настоящий перезапуск")
    monkeypatch.setattr(monitor.restart, "systemctl_restart", нельзя)
    w = monitor.Watchdog()
    w.state = WatchState()
    w.api = API()
    return w


def опрос(сторож, бот, часы, w, раз=1, шаг=60):
    async def сценарий():
        for _ in range(раз):
            await сторож._poll_writers(бот, w)
            часы.now += шаг
    asyncio.run(сценарий())


def про_писателей(бот):
    return [t for t in бот.sent if "ПИСАТЕЛИ" in t and "ДАТА-ЦЕНТР" not in t]


def про_дц(бот):
    return [t for t in бот.sent if "ДАТА-ЦЕНТР" in t]


# --- 1. запасной путь ------------------------------------------------------

def test_с_запасным_путём_не_пугает_и_не_повторяет(сторож, часы):
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), раз=3)
    [тревога] = про_писателей(бот)
    assert "напрямую" in тревога
    assert "будут подключаться и зависать" not in тревога
    # Двенадцать часов аварии — одно сообщение, а не 24 напоминания.
    опрос(сторож, бот, часы, писатели(0), раз=12 * 60, шаг=60)
    assert len(про_писателей(бот)) == 1
    # Отбой приходит как обычно.
    опрос(сторож, бот, часы, писатели(42))
    assert "ВОССТАНОВЛЕНЫ" in про_писателей(бот)[-1]


def test_без_запасного_пути_пугает_и_повторяет(сторож, часы):
    сторож.api.gates = ворота(False)
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), раз=3)
    assert "будут подключаться и зависать" in про_писателей(бот)[0]
    опрос(сторож, бот, часы, писатели(0), раз=31)
    assert len(про_писателей(бот)) == 2
    assert "Авария продолжается" in про_писателей(бот)[1]


@pytest.mark.parametrize("ответ", [RuntimeError("нет связи"), {"ok": True, "data": {}},
                                   {"ok": True, "data": {"me2dc_fallback_enabled": "yes"}}])
def test_не_знаем_про_запасной_путь_ведём_себя_по_старому(сторож, часы, ответ):
    сторож.api.gates = ответ
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), раз=34)
    assert len(про_писателей(бот)) == 2
    assert "будут подключаться и зависать" in про_писателей(бот)[0]


def test_карточка_говорит_про_запасной_путь(сторож, часы):
    опрос(сторож, Бот(), часы, писатели(0), раз=3)
    assert "напрямую" in сторож.render_status()
    сторож.api.gates = ворота(False)
    опрос(сторож, Бот(), часы, писатели(0))
    assert "напрямую" not in сторож.render_status()


# --- 2. отбой по дата-центрам, когда пусто всё ------------------------------

def test_опустевшая_последняя_группа_не_даёт_ложного_отбоя(сторож, часы):
    бот = Бот()
    # 11:22 28.09: жива одна группа из двенадцати — тревога.
    сторож.api.groups = группы({-3: 2})
    опрос(сторож, бот, часы, писатели(2), раз=3)
    assert len(про_дц(бот)) == 1
    # 11:29: опустела и она. Раньше здесь приходило «снова с писателями».
    сторож.api.groups = группы({})
    опрос(сторож, бот, часы, писатели(0), раз=10)
    assert all("СНОВА С ПИСАТЕЛЯМИ" not in t for t in про_дц(бот))
    assert сторож.state.dc_dead.firing
    # Настоящее выздоровление отбой даёт.
    сторож.api.groups = группы(ВСЕ_ЖИВЫ)
    опрос(сторож, бот, часы, писатели(43))
    assert "СНОВА С ПИСАТЕЛЯМИ" in про_дц(бот)[-1]


def test_пустой_пул_тревогу_по_дата_центрам_не_поднимает(сторож, часы):
    # Прежнее правило dcs.py: всё пусто — это не «один дата-центр отвалился».
    бот = Бот()
    сторож.api.groups = группы({})
    опрос(сторож, бот, часы, писатели(0), раз=5)
    assert про_дц(бот) == []


# --- 3. строка про среднее --------------------------------------------------

def test_про_высокое_среднее_говорим_только_когда_оно_высокое(сторож, часы):
    бот = Бот()
    живые = {**ВСЕ_ЖИВЫ, 5: 0, -5: 0}
    сторож.api.groups = группы(живые)
    опрос(сторож, бот, часы, писатели(33), раз=3)         # 77% — как 08.09
    assert "остаётся выше порога" in про_дц(бот)[0]


def test_при_нулевом_покрытии_не_врём_про_среднее(сторож, часы):
    бот = Бот()
    сторож.api.groups = группы({-3: 2})
    опрос(сторож, бот, часы, писатели(2), раз=3)          # 5% — как 28.09
    assert "остаётся выше порога" not in про_дц(бот)[0]
