"""
Клиент API telemt.

ЗАЧЕМ. Через него идёт всё, что сторож знает о состоянии прокси, и именно его
отказы решают, поднимать тревогу или молчать. Проверяется главным образом
разбор НЕудачных ответов: успешный путь ломается заметно, а перепутанный отказ
превращается либо в пропущенную аварию, либо в ложную.

Сеть не трогаем: httpx.AsyncClient подменяется заглушкой. Клиент — одиночка с
состоянием на классе, поэтому фикстура его сбрасывает: без этого первый же
тест зафиксировал бы адрес и заголовки на весь прогон.
"""
import httpx
import pytest

from config import settings
from telemt.api.client import TelemtAPIClient, TelemtAPIError

pytestmark = pytest.mark.asyncio


class _Ответ:
    def __init__(self, code, payload):
        self.status_code = code
        self._payload = payload

    def json(self):
        return self._payload


class _Заглушка:
    """Подменяет httpx.AsyncClient: запоминает вызов и отдаёт заданное."""

    def __init__(self, ответ=None, исключение=None):
        self.ответ = ответ
        self.исключение = исключение
        self.вызовы = []
        self.is_closed = False

    async def request(self, method, url, **kwargs):
        self.вызовы.append((method, url, kwargs))
        if self.исключение:
            raise self.исключение
        return self.ответ

    async def aclose(self):
        self.is_closed = True


@pytest.fixture
def клиент(monkeypatch):
    """Сбрасывает одиночку и отдаёт функцию, подставляющую заглушку."""
    TelemtAPIClient._instance = None
    TelemtAPIClient._client = None
    monkeypatch.setattr(settings, "TELEMT_API_KEY", "", raising=False)

    def собрать(ответ=None, исключение=None):
        c = TelemtAPIClient()
        заглушка = _Заглушка(ответ, исключение)
        TelemtAPIClient._client = заглушка
        return c, заглушка

    yield собрать
    TelemtAPIClient._instance = None
    TelemtAPIClient._client = None


async def test_успешный_ответ_отдаётся_как_есть(клиент):
    c, _ = клиент(_Ответ(200, {"data": {"version": "1.2.3"}}))
    assert await c.system_info() == {"data": {"version": "1.2.3"}}


async def test_users_разворачивает_data(клиент):
    c, _ = клиент(_Ответ(200, {"data": [{"username": "вася"}]}))
    assert await c.users() == [{"username": "вася"}]


async def test_users_без_поля_data_отдаёт_пусто(клиент):
    """Пустой список, а не падение: сторож на этом строит вывод о писателях."""
    c, _ = клиент(_Ответ(200, {}))
    assert await c.users() == []


@pytest.mark.parametrize("код", [400, 401, 403, 404, 500, 502, 503])
async def test_любой_отказ_становится_TelemtAPIError(клиент, код):
    c, _ = клиент(_Ответ(код, {"error": {"message": "нельзя"}}))
    with pytest.raises(TelemtAPIError) as поймано:
        await c.health()
    assert поймано.value.status_code == код
    assert "нельзя" in str(поймано.value)


async def test_отказ_без_описания_не_роняет_разбор(клиент):
    """Чужой сервис вправе не прислать ожидаемую структуру ошибки."""
    c, _ = клиент(_Ответ(500, {}))
    with pytest.raises(TelemtAPIError) as поймано:
        await c.health()
    assert поймано.value.status_code == 500


async def test_обрыв_сети_это_тоже_TelemtAPIError_с_нулевым_кодом(клиент):
    """
    Ноль отличает «не дозвонились» от «ответили отказом». Разница
    принципиальна: первое — авария связи, второе — ответ сервиса.
    """
    c, _ = клиент(исключение=httpx.ConnectError("соединение отклонено"))
    with pytest.raises(TelemtAPIError) as поймано:
        await c.health()
    assert поймано.value.status_code == 0
    assert "соединение отклонено" in str(поймано.value)


async def test_ключ_не_шлётся_когда_не_задан(клиент):
    c, заглушка = клиент(_Ответ(200, {}))
    await c.health()
    _, _, kwargs = заглушка.вызовы[0]
    assert "Authorization" not in kwargs["headers"]


async def test_ключ_шлётся_когда_задан(monkeypatch):
    TelemtAPIClient._instance = None
    TelemtAPIClient._client = None
    monkeypatch.setattr(settings, "TELEMT_API_KEY", "секрет", raising=False)
    c = TelemtAPIClient()
    заглушка = _Заглушка(_Ответ(200, {}))
    TelemtAPIClient._client = заглушка
    await c.health()
    _, _, kwargs = заглушка.вызовы[0]
    assert kwargs["headers"]["Authorization"] == "секрет"
    TelemtAPIClient._instance = None
    TelemtAPIClient._client = None


async def test_имя_пользователя_попадает_в_путь(клиент):
    c, заглушка = клиент(_Ответ(200, {}))
    await c.get_user("вася")
    method, url, _ = заглушка.вызовы[0]
    assert method == "GET"
    assert url.endswith("/v1/users/вася")
