"""
Перезапуск движка сторожем — сам и по кнопке (restart.py).

Опасная сторона здесь не «не перезапустил», а «перезапускает зря»: каждый
перезапуск обрывает всех клиентов. Поэтому большая часть случаев — про то,
когда сторож ОБЯЗАН промолчать: мало подождал, путь закрыт снаружи, спросить
некого, недавно уже перезапускал, перезапуск уже не помог, писатели просто
просели, а не пропали, автоматика выключена.

Настоящий systemctl подменён везде: тест не трогает живую систему.
"""
import asyncio
import time

import pytest

from config import settings
from telemt.watchdog import monitor, restart
from telemt.watchdog.incidents import WatchState

from test_writers_alert import API, Бот, Часы, группы, писатели, ВСЕ_ЖИВЫ


@pytest.fixture
def часы(monkeypatch):
    c = Часы()
    monkeypatch.setattr(time, "time", c)
    return c


@pytest.fixture
def перезапуски(monkeypatch):
    """Подменённый systemctl: запоминает вызовы, всегда «удалось»."""
    calls = []

    async def fake(unit="telemt", timeout=90):
        calls.append(unit)
        return True, ""
    monkeypatch.setattr(monitor.restart, "systemctl_restart", fake)
    return calls


@pytest.fixture
def сторож(monkeypatch, часы, перезапуски):
    monkeypatch.setattr(monitor, "_save_state", lambda state: None)
    monkeypatch.setattr(settings, "ADMIN_IDS", [1])
    monkeypatch.setattr(settings, "WATCHDOG_COVERAGE_FLOOR_PCT", 50)
    monkeypatch.setattr(settings, "WATCHDOG_AUTO_RESTART", True)
    monkeypatch.setattr(settings, "WATCHDOG_RESTART_BELOW_PCT", 10)
    monkeypatch.setattr(settings, "WATCHDOG_RESTART_AFTER_MINUTES", 30)
    monkeypatch.setattr(settings, "WATCHDOG_RESTART_COOLDOWN_HOURS", 6)
    w = monitor.Watchdog()
    w.state = WatchState()
    w.api = API()
    w.api.groups = группы({})
    w.путь = True

    async def путь(_payload):
        return w.путь
    w._path_open = путь
    return w


def опрос(сторож, бот, часы, w, минут=1):
    async def сценарий():
        for _ in range(минут):
            await сторож._poll_writers(бот, w)
            часы.now += 60
    asyncio.run(сценарий())


def с(бот, слово):
    return [t for t in бот.sent if слово in t]


# --- когда перезапускает ----------------------------------------------------

def test_застрявший_движок_перезапускается_один_раз(сторож, часы, перезапуски):
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), минут=30)
    assert перезапуски == []                       # 30 минут ещё не прошло
    опрос(сторож, бот, часы, писатели(0), минут=2)
    assert перезапуски == ["telemt"]
    assert len(с(бот, "СТОРОЖ ПЕРЕЗАПУСТИЛ ДВИЖОК")) == 1


def test_помог_значит_молчит(сторож, часы, перезапуски):
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), минут=32)
    опрос(сторож, бот, часы, писатели(43), минут=30)
    assert с(бот, "НЕ ПОМОГ") == []
    assert сторож.state.restart_note == ""
    assert "ВОССТАНОВЛЕНЫ" in бот.sent[-1]


def test_не_помог_говорит_один_раз_и_больше_не_пробует(сторож, часы, перезапуски):
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), минут=32)
    assert len(перезапуски) == 1
    опрос(сторож, бот, часы, писатели(0), минут=12)
    assert len(с(бот, "НЕ ПОМОГ")) == 1
    # Сутки аварии: пауза в шесть часов истекает, но обещали не пробовать.
    опрос(сторож, бот, часы, писатели(0), минут=24 * 60)
    assert len(перезапуски) == 1
    assert len(с(бот, "НЕ ПОМОГ")) == 1


# --- когда обязан промолчать -------------------------------------------------

def test_путь_закрыт_снаружи_не_перезапускает(сторож, часы, перезапуски):
    сторож.путь = False
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), минут=120)
    assert перезапуски == []
    assert len(с(бот, "НЕ ПЕРЕЗАПУСКАЮ")) == 1


def test_спросить_некого_не_перезапускает(сторож, часы, перезапуски):
    сторож.путь = None
    опрос(сторож, Бот(), часы, писатели(0), минут=60)
    assert перезапуски == []


def test_просевшие_но_живые_писатели_не_повод(сторож, часы, перезапуски):
    # 30% — ниже порога тревоги, но так бывает и от закрытого дата-центра.
    опрос(сторож, Бот(), часы, писатели(13), минут=120)
    assert перезапуски == []


def test_выключенная_автоматика_не_перезапускает(сторож, часы, перезапуски, monkeypatch):
    monkeypatch.setattr(settings, "WATCHDOG_AUTO_RESTART", False)
    бот = Бот()
    опрос(сторож, бот, часы, писатели(0), минут=120)
    assert перезапуски == []
    # Но кнопка под тревогой есть.
    [тревога] = [m for t, m in zip(бот.sent, бот.markups) if "ПРОСЕЛИ ПИСАТЕЛИ" in t]
    assert тревога.inline_keyboard[0][0].callback_data == "wd:restart"


def test_недавний_перезапуск_держит_паузу(сторож, часы, перезапуски):
    # Перезапускали час назад, до этой аварии, — снова только через шесть часов.
    сторож.state.restart_at = часы.now - 3600
    опрос(сторож, Бот(), часы, писатели(0), минут=4 * 60)
    assert перезапуски == []
    опрос(сторож, Бот(), часы, писатели(0), минут=2 * 60 + 5)
    assert перезапуски == ["telemt"]


def test_короткий_провал_не_повод(сторож, часы, перезапуски):
    # Провал на 20 минут, затем писатели есть, затем снова 20 — счёт с нуля.
    for _ in range(3):
        опрос(сторож, Бот(), часы, писатели(0), минут=20)
        опрос(сторож, Бот(), часы, писатели(43), минут=1)
    assert перезапуски == []


# --- кнопка -----------------------------------------------------------------

def test_кнопка_перезапускает_и_ждёт_писателей(сторож, часы, перезапуски, monkeypatch):
    async def мгновенно(_s):
        return None
    monkeypatch.setattr(monitor.asyncio, "sleep", мгновенно)

    async def me_writers():
        return {"data": писатели(42)}
    сторож.api.me_writers = me_writers
    ответ = asyncio.run(сторож.manual_restart())
    assert перезапуски == ["telemt"]
    assert ответ.startswith("✅") and "42 из 43" in ответ
    # Второе нажатие сразу следом — отказ, а не второй обрыв клиентов.
    ответ = asyncio.run(сторож.manual_restart())
    assert перезапуски == ["telemt"]
    assert "меньше двух минут" in ответ


def test_кнопка_честно_говорит_когда_не_помогло(сторож, часы, перезапуски, monkeypatch):
    async def мгновенно(_s):
        return None
    monkeypatch.setattr(monitor.asyncio, "sleep", мгновенно)

    async def me_writers():
        return {"data": писатели(0)}
    сторож.api.me_writers = me_writers
    ответ = asyncio.run(сторож.manual_restart())
    assert ответ.startswith("⚠️") and "0 из 43" in ответ


def test_свой_перезапуск_не_объявляется_чужим(сторож, часы, перезапуски, monkeypatch):
    started = ["1000"]

    async def system_info():
        return {"data": {"process_started_at_epoch_secs": started[0], "version": "3.5.8"}}

    async def me_writers():
        return {"data": писатели(43)}
    сторож.api.system_info = system_info
    сторож.api.me_writers = me_writers
    for name in ("_poll_selftest", "_poll_web", "_poll_beszel"):
        async def ничего(bot):
            return None
        monkeypatch.setattr(сторож, name, ничего)

    async def ничего2(bot, started):
        return None
    monkeypatch.setattr(сторож, "_poll_hard_fails", ничего2)

    бот = Бот()
    asyncio.run(сторож._poll_engine(бот))          # знакомство с отметкой
    сторож.state.restart_at = часы.now             # только что перезапустили сами
    started[0] = "2000"
    asyncio.run(сторож._poll_engine(бот))
    assert с(бот, "Движок перезапустился") == []
    # Чужой перезапуск позже — объявляется, как раньше.
    часы.now += 3600
    started[0] = "3000"
    asyncio.run(сторож._poll_engine(бот))
    assert len(с(бот, "Движок перезапустился")) == 1


# --- разбор точек -----------------------------------------------------------

def test_точки_telegram_из_ответа_движка():
    ответ = {"data": {"dcs": [
        {"dc": -203, "endpoints": ["91.105.192.110:443"]},
        {"dc": 2, "endpoints": ["149.154.167.51:8888", "91.105.192.110:443",
                                "[2001:db8::1]:8888", "мусор", "1.2.3.4:x"]},
        "не словарь",
    ]}}
    assert restart.endpoints(ответ) == [("91.105.192.110", 443), ("149.154.167.51", 8888),
                                        ("2001:db8::1", 8888)]
    assert restart.endpoints(None) == []
    assert restart.endpoints({"data": {}}) == []


def test_без_точек_путь_неизвестен():
    assert asyncio.run(restart.path_open([])) is None
