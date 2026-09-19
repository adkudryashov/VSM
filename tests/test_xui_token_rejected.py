"""
Отказ в токене API — не падение панели.

ЗАЧЕМ. Сроки у токенов API появились в 3x-ui 3.7.0. Прежний опрос считал
падением всё, что не 200, и в день, когда токен кончится, бот объявил бы
«ПАДЕНИЕ» исправного сервера.

Сама панель с 3.8.0 отвечает на плохой токен 401, но nginx 3x-ui-pro
переписывает в 404 и его, и 502 от лежащей панели (замерено на стенде
19.09.2026). Поэтому отличаем по странице входа: у живой панели она 200.

Держим: отказ в токене не считается падением, о нём говорят один раз, а не на
каждом опросе, и снова — если токен починили и он опять сломался. Обратная
сторона: настоящее молчание панели по-прежнему тревога.
"""
import asyncio

import pytest

from config import settings
from xui import app


class _Стоп(BaseException):
    """Выход из бесконечного цикла опроса. Не Exception: тот цикл глотает сам."""


def прогнать(ответы, monkeypatch):
    """
    Крутит цикл опроса одной панели, отдавая по опросу на каждое состояние из списка.
    Возвращает тексты всех сообщений админам по порядку.
    """
    очередь = list(ответы)
    сообщения = []

    async def панели():
        return {"прага": {"base_url": "https://p.example", "token": "т"}}

    async def опрос(base_url, headers):
        состояние = очередь.pop(0)
        return состояние == "ok", 0, состояние

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


def test_отказ_в_токене_не_падение(monkeypatch):
    сообщения = прогнать(["rejected"] * 4, monkeypatch)
    assert not any("ПАДЕНИЕ" in с for с in сообщения)


def test_об_отказе_говорим_один_раз(monkeypatch):
    сообщения = прогнать(["rejected"] * 4, monkeypatch)
    assert len(сообщения) == 1
    assert "токен" in сообщения[0]


def test_после_починки_говорим_снова(monkeypatch):
    сообщения = прогнать(["rejected", "ok", "rejected"], monkeypatch)
    assert sum("токен" in с for с in сообщения) == 2


def test_молчание_панели_по_прежнему_тревога(monkeypatch):
    """Контрольный случай: без ответа вовсе — падение, как и было."""
    сообщения = прогнать(["down", "down"], monkeypatch)
    assert any("ПАДЕНИЕ" in с for с in сообщения)
    assert not any("токен" in с for с in сообщения)


def test_отказ_в_токене_сбрасывает_счёт(monkeypatch):
    """
    Одно молчание, потом отказ в токене, потом снова одно молчание. Порог два, но подряд
    отказов не было ни разу — тревоги быть не должно.
    """
    сообщения = прогнать(["down", "rejected", "down"], monkeypatch)
    assert not any("ПАДЕНИЕ" in с for с in сообщения)


# --- Сама проверка, против настоящего HTTP-сервера ----------------------------

from aiohttp import web

from common import http


def спросить(api, вход):
    """
    Поднимает на петле сервер, где API отвечает кодом api, а страница входа —
    кодом вход, и спрашивает его проверкой бота. None — порт закрыт вовсе.
    """
    async def сценарий():
        async def статус(запрос):
            return web.json_response({"obj": {"cpu": 7}}, status=api)

        async def страница_входа(запрос):
            return web.Response(status=вход)

        app_ = web.Application()
        app_.router.add_get("/panel/api/server/status", статус)
        app_.router.add_get("/", страница_входа)
        runner = web.AppRunner(app_)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        порт = site._server.sockets[0].getsockname()[1]
        try:
            return await app.check_single_panel_status(f"http://127.0.0.1:{порт}", {})
        finally:
            await runner.cleanup()
            await http.close()
    return asyncio.run(сценарий())


def test_исправная_панель():
    assert спросить(200, 200) == (True, 7, "ok")


def test_401_напрямую_это_отказ_в_токене():
    assert спросить(401, 200)[2] == "rejected"


def test_404_от_nginx_при_живой_странице_входа_это_отказ_в_токене():
    """Тот самый случай стенда: через домен 3x-ui-pro токен дал 404."""
    assert спросить(404, 200)[2] == "rejected"


def test_404_и_на_странице_входа_это_падение():
    """Контрольный: панель лежит, nginx отдаёт 404 на всё — замерено остановкой x-ui."""
    assert спросить(404, 404)[2] == "down"


def test_закрытый_порт_это_падение():
    async def сценарий():
        try:
            return await app.check_single_panel_status("http://127.0.0.1:9", {})
        finally:
            await http.close()
    assert asyncio.run(сценарий())[2] == "down"
