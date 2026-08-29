"""
Общая HTTP-сессия: почему она одна и что случится, если её вернут в цикл.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Дефект был беззвучным и смертельным: бот рос по 0.36 МБ
на каждый опрос панели и раз в сутки получал oom-kill от ядра. В журнале
самого бота при этом не было ни строчки — умирал он не сам, его убивали. По
коду `async with aiohttp.ClientSession(...)` выглядит образцово: сессия
закрывается, ресурс освобождается. Заметить можно было только замером RSS.

Поэтому тесты держат не «работает ли запрос», а РОВНО ТО, что чинилось:
сессия одна на процесс и на выходе из блока не закрывается.
"""

import asyncio

from common import http


def прогнать(корутина):
    return asyncio.run(корутина)


def test_сессия_одна_на_несколько_вызовов():
    """
    Главное утверждение. Вернут `ClientSession()` в место вызова — тест
    покажет разные объекты, и утечка не проедет молча.
    """
    async def сценарий():
        async with http.shared_session() as первая:
            a = первая._session
        async with http.shared_session() as вторая:
            b = вторая._session
        await http.close()
        return a, b

    a, b = прогнать(сценарий())
    assert a is b


def test_блок_не_закрывает_сессию():
    """
    Обратная сторона: прежняя форма записи закрывала сессию на выходе, и
    именно отказ от закрытия делает её общей.
    """
    async def сценарий():
        async with http.shared_session() as с:
            сессия = с._session
        закрыта_после_блока = сессия.closed
        await http.close()
        return закрыта_после_блока, сессия.closed

    после_блока, после_close = прогнать(сценарий())
    assert после_блока is False
    assert после_close is True


def test_закрытую_сессию_заменяем_новой():
    """
    Закрыть общую сессию может кто угодно — например, остановка бота,
    пришедшая посреди опроса. Падать из-за этого нельзя.
    """
    async def сценарий():
        async with http.shared_session() as первая:
            a = первая._session
        await http.close()
        async with http.shared_session() as вторая:
            b = вторая._session
        await http.close()
        return a, b

    a, b = прогнать(сценарий())
    assert a is not b
    assert a.closed is True


def test_таймаут_подставляется_в_запрос():
    """
    Прежде таймаут задавался сессии и наследовался запросами. У общей сессии
    такого умолчания нет, и без подстановки места вызова тихо потеряли бы
    свои 4 и 5 секунд — а «тихо потеряли таймаут» означает висящий опрос.
    """
    class Заглушка:
        def __init__(self): self.kw = None
        def get(self, url, **kw): self.kw = kw; return kw
        def post(self, url, **kw): self.kw = kw; return kw
        def request(self, m, url, **kw): self.kw = kw; return kw

    з = Заглушка()
    обёртка = http._Timed(з, "таймаут-5с")
    обёртка.get("https://example.com")
    assert з.kw["timeout"] == "таймаут-5с"
    обёртка.post("https://example.com")
    assert з.kw["timeout"] == "таймаут-5с"
    обёртка.request("GET", "https://example.com")
    assert з.kw["timeout"] == "таймаут-5с"


def test_свой_таймаут_вызова_не_затирается():
    """
    setdefault, а не присваивание: если место вызова задало таймаут само,
    обёртка не должна его перебивать.
    """
    class Заглушка:
        def __init__(self): self.kw = None
        def get(self, url, **kw): self.kw = kw; return kw

    з = Заглушка()
    http._Timed(з, "общий").get("https://example.com", timeout="свой")
    assert з.kw["timeout"] == "свой"


def test_без_таймаута_ничего_не_подставляем():
    """Контрольный случай: обёртка не выдумывает таймаут из воздуха."""
    class Заглушка:
        def __init__(self): self.kw = None
        def get(self, url, **kw): self.kw = kw; return kw

    з = Заглушка()
    http._Timed(з, None).get("https://example.com")
    assert "timeout" not in з.kw


# --- ОБЩИЙ КЛИЕНТ HTTPX ----------------------------------------------
#
# Это и был главный источник утечки, а не aiohttp: сторож зовёт public_ip
# раз в минуту, и каждый вызов создавал свой AsyncClient. Замер против
# настоящего внешнего адреса — 0.76 МБ на вызов при наблюдаемом росте бота
# 0.8 МБ в минуту.

def test_httpx_клиент_один_на_несколько_вызовов():
    async def сценарий():
        async with http.shared_httpx() as первый:
            a = первый._client
        async with http.shared_httpx() as второй:
            b = второй._client
        await http.close()
        return a, b

    a, b = прогнать(сценарий())
    assert a is b


def test_httpx_блок_не_закрывает_клиента():
    async def сценарий():
        async with http.shared_httpx() as к:
            клиент = к._client
        после_блока = клиент.is_closed
        await http.close()
        return после_блока, клиент.is_closed

    после_блока, после_close = прогнать(сценарий())
    assert после_блока is False
    assert после_close is True


def test_httpx_закрытого_заменяем_новым():
    async def сценарий():
        async with http.shared_httpx() as первый:
            a = первый._client
        await http.close()
        async with http.shared_httpx() as второй:
            b = второй._client
        await http.close()
        return a, b

    a, b = прогнать(сценарий())
    assert a is not b
    assert a.is_closed is True


def test_httpx_таймаут_подставляется_и_не_затирается():
    class Заглушка:
        def __init__(self): self.kw = None
        def get(self, url, **kw): self.kw = kw; return kw

    з = Заглушка()
    http._TimedHttpx(з, "общий").get("https://example.com")
    assert з.kw["timeout"] == "общий"
    http._TimedHttpx(з, "общий").get("https://example.com", timeout="свой")
    assert з.kw["timeout"] == "свой"
    http._TimedHttpx(з, None).get("https://example.com")
    assert "timeout" not in з.kw
