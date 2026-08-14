"""
Список панелей 3x-ui с токенами доступа.

ЗАЧЕМ. В этой базе лежат токены доступа к чужим панелям открытым текстом —
самое ценное, что вообще хранят боты. Проверок у неё не было ни одной, а
операции ровно те, где ошибка стоит дорого: добавление с проверкой на дубль,
удаление по имени и продление срока. Все три возвращают bool, и на этих
значениях меню решает, что показать человеку.

DB_NAME подменяется на уровне модуля: он считывается из настроек один раз при
импорте, поэтому правка настройки после импорта ни на что не влияет.
"""
import pytest

from xui import database

pytestmark = pytest.mark.asyncio


@pytest.fixture
async def база(tmp_path, monkeypatch):
    monkeypatch.setattr(database, "DB_NAME", str(tmp_path / "panels.db"))
    await database.init_db()


async def test_добавление_и_чтение(база):
    assert await database.add_new_panel("прага", "https://p.example", "токен-1", "2026-12-31")
    панели = await database.get_all_panels()
    assert панели["прага"]["base_url"] == "https://p.example"
    assert панели["прага"]["token"] == "токен-1"
    assert панели["прага"]["expiry_date"] == "2026-12-31"


async def test_повторное_имя_отклоняется_а_не_затирает(база):
    """
    Имя объявлено UNIQUE, и вторая панель с тем же именем должна получить
    отказ. Молчаливая замена стоила бы токена от первой панели.
    """
    assert await database.add_new_panel("прага", "https://a", "токен-1", None)
    assert await database.add_new_panel("прага", "https://б", "токен-2", None) is False
    панели = await database.get_all_panels()
    assert len(панели) == 1
    assert панели["прага"]["token"] == "токен-1"


async def test_удаление_по_имени(база):
    await database.add_new_panel("прага", "https://a", "т", None)
    await database.add_new_panel("вена", "https://б", "т", None)
    assert await database.delete_panel_by_name("прага") is True
    assert set(await database.get_all_panels()) == {"вена"}


async def test_удаление_несуществующей_отвечает_ложью(база):
    """
    Не исключение и не тихий успех: меню на этом различает «удалил» от
    «удалять было нечего».
    """
    assert await database.delete_panel_by_name("которой-нет") is False


async def test_продление_срока(база):
    await database.add_new_panel("прага", "https://a", "т", "2026-01-01")
    assert await database.update_panel_expiry("прага", "2027-01-01") is True
    панели = await database.get_all_panels()
    assert панели["прага"]["expiry_date"] == "2027-01-01"


async def test_продление_удалённой_отвечает_ложью(база):
    """
    Пока в одной админской сессии открыт календарь, панель могли удалить из
    другой — вызывающий обязан это увидеть.
    """
    assert await database.update_panel_expiry("которой-нет", "2027-01-01") is False


async def test_пустая_база_это_пустой_словарь(база):
    assert await database.get_all_panels() == {}


async def test_init_db_идемпотентна(база):
    await database.add_new_panel("прага", "https://a", "т", None)
    await database.init_db()
    assert len(await database.get_all_panels()) == 1
