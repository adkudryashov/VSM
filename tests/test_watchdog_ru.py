"""
Доступность из России: доходит ли просадка до чата и слышно ли молчание.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Сторож — единственный источник тревог, и обе его беды
беззвучны по своей природе. Первая: связка «вердикт ниже порога → сообщение
админу» не была покрыта ничем — проверялась только машина инцидентов отдельно
и разбор чужого файла отдельно, а провод между ними никто не дёргал. Вторая
хуже: сторож доступность НЕ МЕРЯЕТ, он читает вердикт MTProxyL. Встанет чужой
таймер — сторож замолчит про вход целиком, и его молчание станет неотличимо от
«всё хорошо».

Владелец спросил прямо: «если доступность падает — он информирует?» Ответ
должен быть проверяемым, а не выведенным из чтения кода.
"""

import asyncio
import time

import pytest

from config import settings
from telemt.watchdog import monitor
from telemt.watchdog.incidents import WatchState

ЧАС = 3600.0


class ЗаглушкаБота:
    """Собирает то, что ушло бы в Telegram."""

    def __init__(self):
        self.sent: list[str] = []

    async def send_message(self, chat_id, text, parse_mode=None):
        self.sent.append(text)


def вердикт(pct: float, checked_at: float | None = None) -> dict:
    """Вердикт в том виде, в каком его отдаёт mtproxyl.read_verdict."""
    total = 20
    success = int(round(total * pct / 100))
    return {
        "pct": float(pct), "total": total, "success": success,
        "reasons": {"соединение не установлено": total - success} if success < total else {},
        "probes": [], "source": "mtproxyl", "charged": 0,
        "checked_at": time.time() if checked_at is None else checked_at,
    }


@pytest.fixture
def сторож(monkeypatch):
    """
    Сторож с чистым состоянием, который ничего не пишет на диск.

    Состояние берётся НЕ с диска намеренно: файл боевого сторожа переживает
    перезапуски, и прогон тестов на сервере иначе затирал бы живые тревоги.
    """
    monkeypatch.setattr(monitor, "_save_state", lambda state: None)
    monkeypatch.setattr(settings, "ADMIN_IDS", [1])
    monkeypatch.setattr(settings, "RU_CHECK_STALE_MINUTES", 90)
    w = monitor.Watchdog()
    w.state = WatchState()
    return w


def прогнать(корутина):
    return asyncio.run(корутина)


# --- ПРОСАДКА ДОСТУПНОСТИ --------------------------------------------

def test_просадка_доводит_до_тревоги_и_отбоя(сторож):
    """
    Порог тревоги — RU_CHECK_FLOOR_PCT, гистерезис — три замера подряд. Три
    замера MTProxyL это полтора часа, и это осознанная цена: одиночный плохой
    замер бывает от самих зондов.
    """
    bot = ЗаглушкаБота()

    async def сценарий():
        for _ in range(3):
            await сторож._apply_ru_verdict(bot, вердикт(0))
        assert len(bot.sent) == 1, "тревога обязана уйти ровно один раз"
        assert "ПАДЕНИЕ ДОСТУПНОСТИ ИЗ РОССИИ" in bot.sent[0]
        assert "0 из 20" in bot.sent[0]

        await сторож._apply_ru_verdict(bot, вердикт(100))
        assert len(bot.sent) == 2
        assert "ВОССТАНОВЛЕНА" in bot.sent[1]

    прогнать(сценарий())


def test_одна_просадка_не_будит(сторож):
    """
    Обратная сторона: без этого проверка выше прошла бы и у сторожа, который
    кричит на первый же плохой замер.
    """
    bot = ЗаглушкаБота()
    прогнать(сторож._apply_ru_verdict(bot, вердикт(0)))
    assert bot.sent == []


def test_просадка_выше_порога_молчит(сторож):
    """
    Порог — «рухнуло», а не «ухудшилось». 70% при пороге 50 это жёлтый в
    карточке, но не сообщение: светофор показывает, а будит только красный.
    """
    bot = ЗаглушкаБота()

    async def сценарий():
        for _ in range(5):
            await сторож._apply_ru_verdict(bot, вердикт(70))

    прогнать(сценарий())
    assert bot.sent == []


# --- МОЛЧАНИЕ ЧУЖОЙ ПРОВЕРКИ -----------------------------------------

def test_протухший_вердикт_поднимает_тревогу(сторож):
    """
    Главное, ради чего правилось. Прежде об этом говорилось только в карточке —
    то есть лишь тому, кто сам решил посмотреть.
    """
    bot = ЗаглушкаБота()
    сторож.ru_checked_at = time.time() - 3 * ЧАС
    сторож._started_at = time.time() - 3 * ЧАС

    прогнать(сторож._check_ru_stale(bot))
    assert len(bot.sent) == 1
    assert "НЕ ПРОВЕРЯЕТСЯ" in bot.sent[0]
    # Тревога обязана сказать, что делать: чинится это не у нас.
    assert "mtproxyl availability on" in bot.sent[0]
    # И в карточке причина тоже названа.
    assert "не обновлялась" in сторож.ru_error


def test_свежий_вердикт_даёт_отбой(сторож):
    """Чужой таймер починили — сторож обязан сказать и об этом."""
    bot = ЗаглушкаБота()
    сторож.ru_checked_at = time.time() - 3 * ЧАС
    сторож._started_at = time.time() - 3 * ЧАС

    async def сценарий():
        await сторож._check_ru_stale(bot)
        сторож.ru_checked_at = time.time()
        await сторож._check_ru_stale(bot)

    прогнать(сценарий())
    assert len(bot.sent) == 2
    assert "ПРОВЕРКА ДОСТУПНОСТИ ВЕРНУЛАСЬ" in bot.sent[1]


def test_после_перезапуска_не_кричит_сразу(сторож):
    """
    Ловушка, из-за которой и появился запасной якорь: сразу после перезапуска
    ru_checked_at ещё ноль, и возраст, посчитанный от него, даёт полвека. Без
    якоря тревога уходила бы на КАЖДОМ обновлении бота — а ложная тревога при
    каждом обновлении обесценивает все остальные.
    """
    bot = ЗаглушкаБота()
    assert сторож.ru_checked_at == 0.0, "предпосылка проверки"
    сторож._started_at = time.time()

    прогнать(сторож._check_ru_stale(bot))
    assert bot.sent == []


def test_срок_молчания_берётся_из_настроек(сторож, monkeypatch):
    """
    Контрольный случай к порогу: чуть раньше срока — тишина, чуть позже —
    тревога. Без обеих сторон проверка не отличает работающий порог от
    молчащей функции.
    """
    monkeypatch.setattr(settings, "RU_CHECK_STALE_MINUTES", 90)
    bot = ЗаглушкаБота()

    сторож._started_at = time.time() - 89 * 60
    сторож.ru_checked_at = сторож._started_at
    прогнать(сторож._check_ru_stale(bot))
    assert bot.sent == []

    сторож._started_at = time.time() - 91 * 60
    сторож.ru_checked_at = сторож._started_at
    прогнать(сторож._check_ru_stale(bot))
    assert len(bot.sent) == 1


def test_ненужный_вердикт_снимает_тревогу(сторож):
    """
    Проверку выключили или сторож стал мерять сам. Требовать чинить то, чего мы
    больше не спрашиваем, — способ приучить владельца не читать тревоги.
    """
    bot = ЗаглушкаБота()
    сторож.ru_checked_at = time.time() - 3 * ЧАС
    сторож._started_at = time.time() - 3 * ЧАС

    async def сценарий():
        await сторож._check_ru_stale(bot)
        await сторож._check_ru_stale(bot, watching=False)

    прогнать(сценарий())
    assert len(bot.sent) == 2
    assert "ВЕРНУЛАСЬ" in bot.sent[1]


def test_заглушка_держит_и_эту_тревогу(сторож):
    """
    Пауза в карточке обязана глушить ВСЕ тревоги. Новый вид легко забыть
    обернуть — здесь проверяется, что он проходит через общую рассылку.
    """
    bot = ЗаглушкаБота()
    сторож.state.muted_until = -1
    сторож.ru_checked_at = time.time() - 3 * ЧАС
    сторож._started_at = time.time() - 3 * ЧАС

    прогнать(сторож._check_ru_stale(bot))
    assert bot.sent == []
