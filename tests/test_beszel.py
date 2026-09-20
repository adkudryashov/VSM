"""
Хаб beszel: чтение и разбор.

ЗАЧЕМ. beszel следит за железом четырёх серверов, бот — за прокси на одном.
Свести их в боте имеет смысл только если он честно отличает три вещи: хаб
молчит, хаб не принимает пароль, отдельный сервер перестал отчитываться.

Первое — та самая дыра, ради которой всё затевалось: если ляжет сам хаб,
сообщения о железе просто перестанут приходить, а молчание неотличимо от
«всё хорошо». Ровно это мы уже проходили с самим ботом.

Второе — урок, оплаченный на панелях 3x-ui: там любое не-200 считалось
падением, и в день окончания срока токена бот объявил бы аварию на исправном
сервере.
"""
import asyncio
import json
import time

import pytest
from aiohttp import web

from common import beszel as клиент
from common import http
from telemt.watchdog import beszel_hub as разбор


СЕЙЧАС = 1_000_000.0


def момент(отступ_секунд: float) -> str:
    """Время в том виде, в каком его пишет хаб: с пробелом и всегда в UTC."""
    t = time.gmtime(СЕЙЧАС - отступ_секунд)
    return time.strftime("%Y-%m-%d %H:%M:%S", t) + ".000Z"


def сервер(имя, *, status="up", возраст=10, cpu=2.5, mp=30.0, dp=40.0,
           u=86400 * 3, sv=(59, 0), info_строкой=False):
    данные = {"cpu": cpu, "mp": mp, "dp": dp, "u": u, "sv": list(sv)}
    return {
        "name": имя,
        "status": status,
        "updated": момент(возраст),
        "info": json.dumps(данные) if info_строкой else данные,
    }


def ответ(*серверы, state="ok", error=""):
    return клиент.HubAnswer(state, list(серверы), error)


# --- Разбор -----------------------------------------------------------------

def test_всё_в_порядке():
    v = разбор.read_verdict(ответ(сервер("FST.KZ"), сервер("VEESP")), СЕЙЧАС)
    assert v.hub_ok
    assert v.silent == [] and v.offline == []
    assert [r.name for r in v.rows] == ["FST.KZ", "VEESP"]
    assert all(r.alive for r in v.rows)


def test_молчащий_сервер_замечен():
    v = разбор.read_verdict(ответ(сервер("P2GO", возраст=400)), СЕЙЧАС)
    assert v.silent == ["P2GO"]
    assert v.rows[0].alive is False


def test_свежий_доклад_не_считается_молчанием():
    """Обратная сторона: порог не должен срабатывать на обычной задержке."""
    v = разбор.read_verdict(ответ(сервер("P2GO", возраст=299)), СЕЙЧАС)
    assert v.silent == []


def test_упавший_по_мнению_хаба():
    v = разбор.read_verdict(ответ(сервер("1cent", status="down", возраст=900)), СЕЙЧАС)
    assert v.offline == ["1cent"]
    # В обоих списках сразу он быть не должен: причина одна, и сообщений о ней
    # тоже должно быть одно.
    assert v.silent == []


def test_приостановленный_не_авария():
    """
    Контрольный случай. Сервер, снятый с наблюдения вручную, молчит по
    определению. Считать это бедой значит спорить с решением владельца.
    """
    v = разбор.read_verdict(ответ(сервер("P2GO", status="paused", возраст=99999)), СЕЙЧАС)
    assert v.silent == [] and v.offline == []
    assert v.trouble == []


def test_беда_поднимается_наверх():
    v = разбор.read_verdict(
        ответ(сервер("аааа"), сервер("яяяя", status="down"), сервер("бббб", возраст=999)),
        СЕЙЧАС)
    assert [r.name for r in v.rows][:2] == ["бббб", "яяяя"] or \
           [r.name for r in v.rows][:2] == ["яяяя", "бббб"]
    assert v.rows[-1].name == "аааа"


def test_пустой_хаб_не_авария():
    """Сразу после установки серверов нет вовсе — это не поломка."""
    v = разбор.read_verdict(ответ(), СЕЙЧАС)
    assert v.hub_ok and v.trouble == []


def test_отказ_в_пароле_не_падение():
    v = разбор.read_verdict(ответ(state="rejected", error="не тот пароль"), СЕЙЧАС)
    assert v.state == "rejected"
    assert not v.hub_ok
    assert v.rows == []


def test_info_строкой_тоже_разбирается():
    """Хаб отдаёт info то объектом, то строкой — зависит от версии."""
    v = разбор.read_verdict(ответ(сервер("FST.KZ", info_строкой=True, cpu=7.5)), СЕЙЧАС)
    assert v.rows[0].cpu == 7.5


def test_мусор_вместо_времени_не_роняет_опрос():
    битый = сервер("FST.KZ")
    битый["updated"] = "позавчера"
    v = разбор.read_verdict(ответ(битый), СЕЙЧАС)
    # Времени нет — считаем, что сервер молчит: это честнее, чем показать его
    # живым на основании того, что дату не смогли прочитать.
    assert v.silent == ["FST.KZ"]


def test_время_хаба_читается_как_utc():
    """
    Контрольный случай на часовой пояс. Хаб пишет UTC, сервер живёт по Алматы
    (+5). Приняв время за местное, бот насчитал бы пять часов молчания у
    только что отчитавшегося сервера.
    """
    свежий = сервер("FST.KZ", возраст=5)
    v = разбор.read_verdict(ответ(свежий), СЕЙЧАС)
    assert v.silent == []


@pytest.mark.parametrize("секунд,ожидаем", [
    (0, "—"),
    (1800, "меньше часа"),
    (7200, "2 ч"),
    (86400, "1 день"),
    (86400 * 3, "3 дня"),
    (86400 * 5, "5 дней"),
    (86400 * 11, "11 дней"),
    (86400 * 21, "21 день"),
    (86400 * 24, "24 дня"),
])
def test_срок_словами(секунд, ожидаем):
    assert разбор.срок(секунд) == ожидаем


# --- Клиент, против настоящего HTTP-сервера ---------------------------------

def спросить(вход_код=200, список_кодов=(200,), серверов=1):
    """
    Поднимает подделку хаба: вход отвечает кодом вход_код, а список серверов
    отдаёт коды из список_кодов по очереди. Возвращает ответ клиента.
    """
    коды = list(список_кодов)
    входов = {"счёт": 0}

    async def сценарий():
        async def вход(запрос):
            входов["счёт"] += 1
            if вход_код != 200:
                return web.json_response({"message": "Failed to authenticate."},
                                         status=вход_код)
            return web.json_response({"token": f"т{входов['счёт']}"})

        async def список(запрос):
            код = коды.pop(0) if коды else 200
            if код != 200:
                return web.json_response({}, status=код)
            items = [сервер(f"с{i}") for i in range(серверов)]
            return web.json_response({"items": items, "totalItems": len(items)})

        app_ = web.Application()
        app_.router.add_post("/api/collections/users/auth-with-password", вход)
        app_.router.add_get("/api/collections/systems/records", список)
        runner = web.AppRunner(app_)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        порт = site._server.sockets[0].getsockname()[1]
        try:
            хаб = клиент.Beszel(f"http://127.0.0.1:{порт}", "кто@example.com", "пароль")
            результат = await хаб.systems()
            return результат, входов["счёт"]
        finally:
            await runner.cleanup()
            await http.close()

    return asyncio.run(сценарий())


def test_исправный_хаб_отдаёт_список():
    результат, входов = спросить(серверов=3)
    assert результат.state == "ok"
    assert len(результат.systems) == 3
    assert входов == 1


def test_неверный_пароль_это_отказ_а_не_падение():
    результат, _ = спросить(вход_код=400)
    assert результат.state == "rejected"
    assert результат.systems == []


def test_протухший_токен_обновляется_молча():
    """
    Срок токена кончается без предупреждения. Без повторного входа бот объявил
    бы потерю хаба ровно в этот момент — на исправном сервере.
    """
    результат, входов = спросить(список_кодов=(401, 200))
    assert результат.state == "ok"
    assert входов == 2, "после отказа обязан быть второй вход"


def test_отказ_дважды_подряд_это_отказ():
    """Обратная сторона: повтор не должен зацикливаться."""
    результат, входов = спросить(список_кодов=(401, 403))
    assert результат.state == "rejected"
    assert входов == 2


def test_закрытый_порт_это_падение():
    async def сценарий():
        try:
            хаб = клиент.Beszel("http://127.0.0.1:9", "кто@example.com", "пароль")
            return await хаб.systems()
        finally:
            await http.close()
    assert asyncio.run(сценарий()).state == "down"


def test_ненастроенный_хаб_молчит_понятно():
    async def сценарий():
        return await клиент.Beszel("", "", "").systems()
    результат = asyncio.run(сценарий())
    assert результат.state == "down"
    assert "не подключён" in результат.error
