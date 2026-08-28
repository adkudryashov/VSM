"""
Хранилище истории IP.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Здесь единственная в проекте операция, которая УДАЛЯЕТ
пользовательские данные безвозвратно: cleanup_old_ips сносит записи об
адресах. От массового удаления защищает ровно одна строка — `retention_hours
<= 0` возвращает ноль, ничего не тронув, — и по умолчанию настройка стоит
именно в ноль (ACTIVITY_RETENTION_HOURS=0, «хранить бессрочно»). Если эта
защита однажды отвалится, весь журнал подключений исчезнет молча и
восстановить его будет неоткуда.

Поэтому проверяется обе стороны: что при выключенной очистке не удаляется
НИЧЕГО и что при включённой удаляется ТОЛЬКО старое.

DB_PATH подменяется на уровне модуля, а не через настройки: storage.py
считывает settings.IP_HISTORY_DB один раз при импорте, поэтому правка
настройки после импорта ни на что не влияет. Это заодно и наблюдение о самом
коде — путь к базе там зафиксирован намертво.
"""
from datetime import datetime, timedelta, timezone

import pytest

from telemt.utils import storage

pytestmark = pytest.mark.asyncio


@pytest.fixture
def база(tmp_path, monkeypatch):
    monkeypatch.setattr(storage, "DB_PATH", str(tmp_path / "ip_history.db"))
    return storage.DB_PATH


def _метка(часов_назад: int) -> str:
    момент = datetime.now(timezone.utc) - timedelta(hours=часов_назад)
    return момент.isoformat(timespec="minutes")


async def _положить(username: str, ip: str, часов_назад: int) -> None:
    """Кладёт запись с заданным возрастом. Пишем напрямую: bulk_save_ips
    всегда ставит текущее время, а нам нужна именно старая."""
    import aiosqlite
    метка = _метка(часов_назад)
    async with aiosqlite.connect(storage.DB_PATH) as db:
        await db.execute(
            "INSERT INTO ip_log (username, ip, first_seen, last_seen, count) "
            "VALUES (?, ?, ?, ?, 1)", (username, ip, метка, метка))
        await db.commit()


async def test_запись_и_чтение(база):
    await storage.init_db()
    await storage.bulk_save_ips([("вася", "1.2.3.4"), ("петя", "5.6.7.8")])
    все = await storage.get_all_ips_by_user()
    assert set(все) == {"вася", "петя"}
    assert все["вася"][0][0] == "1.2.3.4"


async def test_повтор_того_же_адреса_наращивает_счётчик(база):
    """Уникальный индекс по (username, ip) плюс ON CONFLICT: вторая встреча
    того же адреса — не новая строка, а +1 к счётчику."""
    await storage.init_db()
    await storage.bulk_save_ips([("вася", "1.2.3.4")])
    await storage.bulk_save_ips([("вася", "1.2.3.4")])
    строки = await storage.get_ips_by_username("вася")
    assert len(строки) == 1
    assert строки[0][3] == 2


async def test_пустой_список_не_ходит_в_базу(база):
    """Без раннего выхода executemany на пустых данных — лишняя транзакция."""
    await storage.init_db()
    await storage.bulk_save_ips([])
    assert await storage.get_all_ips_by_user() == {}


# --- Удаление: обе стороны защиты ------------------------------------------

@pytest.mark.parametrize("срок", [0, -1, -100])
async def test_выключенная_очистка_не_удаляет_НИЧЕГО(база, срок):
    """
    Умолчание проекта — ноль, «хранить бессрочно». Здесь лежат записи возрастом
    в год: если защита отвалится, тест это увидит.
    """
    await storage.init_db()
    await _положить("вася", "1.2.3.4", часов_назад=24 * 365)
    await _положить("петя", "5.6.7.8", часов_назад=1)

    удалено = await storage.cleanup_old_ips(срок)

    assert удалено == 0
    assert len(await storage.get_all_ips_by_user()) == 2


async def test_включённая_очистка_удаляет_только_старое(база):
    await storage.init_db()
    await _положить("древний", "1.1.1.1", часов_назад=100)
    await _положить("вчерашний", "2.2.2.2", часов_назад=25)
    await _положить("свежий", "3.3.3.3", часов_назад=1)

    удалено = await storage.cleanup_old_ips(24)

    assert удалено == 2
    осталось = await storage.get_all_ips_by_user()
    assert set(осталось) == {"свежий"}


async def test_очистка_на_пустой_базе_не_падает(база):
    await storage.init_db()
    assert await storage.cleanup_old_ips(24) == 0


async def test_init_db_идемпотентна(база):
    """Вызывается при каждом запуске бота — второй раз не должен ничего стоить."""
    await storage.init_db()
    await storage.bulk_save_ips([("вася", "1.2.3.4")])
    await storage.init_db()
    assert len(await storage.get_all_ips_by_user()) == 1


# ======================================================================
# РУЧНАЯ ОЧИСТКА
#
# Второе безвозвратное удаление в проекте, и в отличие от cleanup_old_ips его
# запускает человек кнопкой. Защиты «ничего не делать по умолчанию» здесь нет
# по замыслу: нажали — стёрли. Поэтому проверяется не наличие предохранителя, а
# ТОЧНОСТЬ ПРИЦЕЛА: удаление по имени обязано унести только это имя.
#
# И обратная сторона: несуществующее имя не должно уносить ничего. Без этой
# проверки «удаляет по имени» подтверждалось бы и полным стиранием таблицы.
# ======================================================================

async def test_очистка_по_имени_уносит_только_это_имя(база):
    await storage.init_db()
    await storage.bulk_save_ips([("вася", "1.1.1.1"), ("вася", "2.2.2.2"),
                                 ("петя", "3.3.3.3")])

    удалено = await storage.purge_history("вася")

    assert удалено == 2
    assert set(await storage.get_all_ips_by_user()) == {"петя"}


async def test_очистка_несуществующего_имени_не_трогает_ничего(база):
    """Обратная сторона: без неё «удаляет по имени» подтверждалось бы и стиранием всего."""
    await storage.init_db()
    await storage.bulk_save_ips([("вася", "1.1.1.1"), ("петя", "3.3.3.3")])

    удалено = await storage.purge_history("никого-нет")

    assert удалено == 0
    assert set(await storage.get_all_ips_by_user()) == {"вася", "петя"}


async def test_очистка_всего_опустошает_таблицу(база):
    await storage.init_db()
    await storage.bulk_save_ips([("вася", "1.1.1.1"), ("петя", "3.3.3.3")])

    удалено = await storage.purge_history()

    assert удалено == 2
    assert await storage.get_all_ips_by_user() == []


async def test_очистка_на_отсутствующей_базе_не_падает(база):
    """Свежая установка: сбор ещё не шёл, файла нет. Это не ошибка, а пустая история."""
    assert await storage.purge_history() == 0
    assert await storage.purge_history("вася") == 0


async def test_сводка_на_отсутствующей_базе_пуста(база):
    st = await storage.history_stats()
    assert st["rows"] == 0 and st["users"] == 0
    assert await storage.history_usernames() == []


async def test_сводка_считает_записи_адреса_и_имена(база):
    await storage.init_db()
    await storage.bulk_save_ips([("вася", "1.1.1.1"), ("вася", "2.2.2.2"),
                                 ("петя", "1.1.1.1")])

    st = await storage.history_stats()

    assert st["rows"] == 3      # три пары «имя + адрес»
    assert st["ips"] == 2       # адресов всего два
    assert st["users"] == 2
    assert dict(await storage.history_usernames()) == {"вася": 2, "петя": 1}
