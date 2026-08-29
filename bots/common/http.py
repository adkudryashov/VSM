"""
Одна общая HTTP-сессия на весь процесс.

ЗАЧЕМ. Бота убивало ядром по превышению памяти: 29.08.2026 в 12:52
`oom-kill` при RSS 609 МБ, и через 11 часов он снова дошёл до 589 МБ.
Замер роста — 940 КБ за 90 секунд, ровно по 0.36 МБ на каждый опрос панели
раз в минуту. Разбор `/proc/<pid>/smaps` показал 475 МБ в куче процесса,
то есть накопление объектов, а не отображённые файлы.

Причина — `aiohttp.ClientSession()` НА КАЖДЫЙ ЗАПРОС. Контрольный замер на
стенде, сорок итераций подряд:

    сессия на каждый запрос: +0.36 МБ на итерацию
    одна общая сессия:       +0.00 МБ на итерацию

Первой гипотезой был разбор хранилища корневых сертификатов: один
`ssl.create_default_context()` стоит 0.68 МБ и после `del` с `gc.collect()`
память не возвращается. Гипотеза НЕ подтвердилась — передача общего
контекста в запрос роста не убрала (0.36 против 0.37 МБ). Дело именно в
сессии целиком, и записано это здесь, чтобы никто не чинил повторно то,
что уже проверено.

ПОЧЕМУ КОНТЕКСТНЫЙ МЕНЕДЖЕР, А НЕ ПРОСТАЯ ФУНКЦИЯ. Места вызова написаны
как `async with aiohttp.ClientSession(...) as session:` и дальше телом с
отступом. Замена на функцию потребовала бы сдвинуть тело каждого блока —
правка на десятки строк там, где по смыслу меняется одна. Здесь та же
форма, но сессия отдаётся общая и НЕ закрывается на выходе.

ТАЙМАУТ. Прежде он задавался сессии и наследовался запросами. У общей
сессии такого умолчания нет, поэтому обёртка подставляет таймаут вызова в
каждый запрос — поведение остаётся прежним, а не «как получится».
"""

import contextlib
import logging
from typing import Optional

import aiohttp
import httpx

_session: Optional[aiohttp.ClientSession] = None
_httpx: Optional[httpx.AsyncClient] = None


class _Timed:
    """Общая сессия, подставляющая таймаут конкретного места вызова."""

    def __init__(self, session: aiohttp.ClientSession, timeout) -> None:
        self._session = session
        self._timeout = timeout

    def _kw(self, kw: dict) -> dict:
        if self._timeout is not None:
            kw.setdefault("timeout", self._timeout)
        return kw

    def request(self, method: str, url: str, **kw):
        return self._session.request(method, url, **self._kw(kw))

    def get(self, url: str, **kw):
        return self._session.get(url, **self._kw(kw))

    def post(self, url: str, **kw):
        return self._session.post(url, **self._kw(kw))


@contextlib.asynccontextmanager
async def shared_session(timeout=None):
    """
    Отдаёт общую сессию и НЕ закрывает её на выходе.

    Закрытая сессия заменяется новой: aiohttp не позволяет пользоваться
    закрытой, а падать посреди опроса панели из-за чужого закрытия незачем.
    """
    global _session
    if _session is None or _session.closed:
        _session = aiohttp.ClientSession()
    yield _Timed(_session, timeout)


async def close() -> None:
    """Закрыть общие сессию и клиент. Зовётся при остановке бота."""
    global _session
    if _session is not None and not _session.closed:
        try:
            await _session.close()
        except Exception as exc:
            logging.warning("Общая HTTP-сессия не закрылась: %s", exc)
    _session = None

    global _httpx
    if _httpx is not None and not _httpx.is_closed:
        try:
            await _httpx.aclose()
        except Exception as exc:
            logging.warning("Общий httpx-клиент не закрылся: %s", exc)
    _httpx = None


class _TimedHttpx:
    """Общий клиент httpx, подставляющий таймаут места вызова."""

    def __init__(self, client: "httpx.AsyncClient", timeout) -> None:
        self._client = client
        self._timeout = timeout

    def _kw(self, kw: dict) -> dict:
        if self._timeout is not None:
            kw.setdefault("timeout", self._timeout)
        return kw

    def get(self, url: str, **kw):
        return self._client.get(url, **self._kw(kw))

    def post(self, url: str, **kw):
        return self._client.post(url, **self._kw(kw))

    def request(self, method: str, url: str, **kw):
        return self._client.request(method, url, **self._kw(kw))


@contextlib.asynccontextmanager
async def shared_httpx(timeout=None):
    """
    То же самое для httpx и по той же причине.

    ЭТО ГЛАВНЫЙ ИСТОЧНИК УТЕЧКИ, а не aiohttp. Сторож зовёт globalping.public_ip
    раз в минуту, и каждый вызов создавал свой AsyncClient. Замер на стенде
    30.08.2026 против НАСТОЯЩЕГО внешнего адреса (api.ipify.org, ровно туда
    ходит бот):

        клиент на каждый вызов: 0.76 МБ
        один общий клиент:      0.06 МБ

    Наблюдаемый рост бота был 0.8 МБ в минуту — сходится с точностью до
    сотых.

    ОСТОРОЖНО С МЕТОДИКОЙ. Первые замеры я делал против 127.0.0.1:9443, где
    проверка имени обрывает рукопожатие рано, и они занижали цену в пятнадцать
    раз: 0.05 МБ вместо 0.76. Мерить надо там же, куда ходит проверяемый код,
    иначе получается аккуратное число не про то.
    """
    global _httpx
    if _httpx is None or _httpx.is_closed:
        _httpx = httpx.AsyncClient()
    yield _TimedHttpx(_httpx, timeout)
