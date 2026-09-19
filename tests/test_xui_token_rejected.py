"""
Отказ в токене API — не падение панели.

ЗАЧЕМ. С 3x-ui 3.8.0 неверный, отключённый и просроченный токен получает 401
(до этого — 404, неотличимое от неверного адреса), а сроки у токенов появились
в 3.7.0. Прежний опрос считал падением всё, что не 200, и в день, когда токен
кончится, бот объявил бы «ПАДЕНИЕ» исправного сервера.

Держим три вещи: 401 не считается падением, о нём говорят один раз, а не на
каждом опросе, и говорят снова, если токен успели починить и он опять сломался.
Обратная сторона тоже держится: настоящее молчание панели по-прежнему тревога.
"""
import asyncio

import pytest

from config import settings
from xui import app


class _Стоп(BaseException):
    """Выход из бесконечного цикла опроса. Не Exception: тот цикл глотает сам."""


def прогнать(ответы, monkeypatch):
    """
    Крутит цикл опроса одной панели, отдавая по опросу на каждый код из списка.
    Возвращает тексты всех сообщений админам по порядку.
    """
    очередь = list(ответы)
    сообщения = []

    async def панели():
        return {"прага": {"base_url": "https://p.example", "token": "т"}}

    async def опрос(base_url, headers):
        код = очередь.pop(0)
        return код == 200, 0, код

    async def уведомить(bot, text):
        сообщения.append(text)

    async def пауза(секунды):
        if not очередь:
            raise _Стоп

    monkeypatch.setattr(app, "get_all_panels", панели)
    monkeypatch.setattr(app, "check_single_panel_status", опрос)
    monkeypatch.setattr(app, "_notify_admins", уведомить)
    monkeypatch.setattr(app.asyncio, "sleep", пауза)
    monkeypatch.setattr(settings, "XUI_FAILURES_BEFORE_ALERT", 2)

    with pytest.raises(_Стоп):
        asyncio.run(app.monitor_servers_loop(bot=None))
    return сообщения


def test_401_не_падение(monkeypatch):
    сообщения = прогнать([401, 401, 401, 401], monkeypatch)
    assert not any("ПАДЕНИЕ" in с for с in сообщения)


def test_401_говорим_один_раз(monkeypatch):
    сообщения = прогнать([401, 401, 401, 401], monkeypatch)
    assert len(сообщения) == 1
    assert "токен" in сообщения[0]


def test_после_починки_говорим_снова(monkeypatch):
    сообщения = прогнать([401, 200, 401], monkeypatch)
    assert sum("токен" in с for с in сообщения) == 2


def test_молчание_панели_по_прежнему_тревога(monkeypatch):
    """Контрольный случай: без ответа вовсе — падение, как и было."""
    сообщения = прогнать([None, None], monkeypatch)
    assert any("ПАДЕНИЕ" in с for с in сообщения)
    assert not any("токен" in с for с in сообщения)


def test_401_сбрасывает_счёт_отказов(monkeypatch):
    """
    Одно молчание, потом 401, потом снова одно молчание. Порог два, но подряд
    отказов не было ни разу — тревоги быть не должно.
    """
    сообщения = прогнать([None, 401, None], monkeypatch)
    assert not any("ПАДЕНИЕ" in с for с in сообщения)
