"""
Чтение из хаба beszel.

ЗАЧЕМ. beszel следит за железом всех серверов владельца, а бот — за прокси на
одном. Вместе они дают полную картину, но только если кто-то их сводит.

ЧТО ВАЖНО ЗНАТЬ ПРО ЭТОТ ХАБ.

Внутри него PocketBase. Список серверов лежит в коллекции systems и БЕЗ входа
не отдаётся: запрос проходит, отвечает 200, а список приходит пустой (замерено
20.09.2026: totalItems 0 при четырёх заведённых серверах). Поэтому боту нужна
своя учётная запись, а пустой ответ нельзя считать «серверов нет».

Вход — POST /api/collections/users/auth-with-password, в ответе поле token.
Дальше он идёт в заголовке Authorization КАК ЕСТЬ, без слова Bearer: так
описано в справке самого PocketBase, встроенной в хаб.

ОТКАЗ В ПАРОЛЕ И МОЛЧАНИЕ ХАБА — РАЗНОЕ. Этот урок проект уже оплатил на
панелях 3x-ui: там всё, что не 200, считалось падением, и в день, когда
кончился бы срок токена, бот объявил бы аварию на исправном сервере. Здесь
состояние называется прямо: ok, rejected, down.
"""
import json
import logging
from dataclasses import dataclass

from common import http

logger = logging.getLogger(__name__)

# Хаб слушает петлю, поэтому пять секунд — уже щедро. Долгий таймаут здесь
# вреден: опрос идёт внутри цикла сторожа, и зависший запрос задержал бы
# проверки прокси, которые важнее.
TIMEOUT = 5


@dataclass
class HubAnswer:
    """
    Ответ хаба. state: ok | rejected | down.

    rejected — хаб жив, но не принимает учётную запись (сменили пароль, удалили
    пользователя). Это НЕ авария сервера, и говорить о ней надо иначе.
    """
    state: str
    systems: list
    error: str = ""

    @property
    def ok(self) -> bool:
        return self.state == "ok"


class Beszel:
    def __init__(self, url: str, email: str, password: str):
        self.url = (url or "").rstrip("/")
        self.email = email
        self.password = password
        self._token = ""

    @property
    def configured(self) -> bool:
        return bool(self.url and self.email and self.password)

    async def _login(self) -> str:
        session = await http.shared_session()
        async with session.post(
            f"{self.url}/api/collections/users/auth-with-password",
            json={"identity": self.email, "password": self.password},
            timeout=TIMEOUT,
        ) as resp:
            if resp.status != 200:
                # 400 здесь означает именно «не тот пароль»: путь существует,
                # хаб отвечает. Проверено на стенде — несуществующая коллекция
                # даёт 404, неверный пароль 400.
                raise PermissionError(f"хаб не принял учётную запись (код {resp.status})")
            data = await resp.json()
        token = (data or {}).get("token") or ""
        if not token:
            raise PermissionError("хаб ответил на вход без токена")
        self._token = token
        return token

    async def _get_systems(self) -> list:
        session = await http.shared_session()
        async with session.get(
            f"{self.url}/api/collections/systems/records",
            params={"perPage": "200", "sort": "name"},
            headers={"Authorization": self._token},
            timeout=TIMEOUT,
        ) as resp:
            if resp.status in (401, 403):
                raise PermissionError(f"хаб отверг токен (код {resp.status})")
            resp.raise_for_status()
            return ((await resp.json()) or {}).get("items") or []

    async def systems(self) -> HubAnswer:
        """
        Список серверов из хаба.

        Вход происходит по необходимости, а не при каждом опросе: токен живёт
        долго, а лишний вход — лишний запрос раз в минуту и лишняя строка в
        журнале хаба. Один повтор после отказа обязателен: срок токена кончается
        молча, и без повтора бот объявил бы потерю хаба ровно в этот момент.
        """
        if not self.configured:
            return HubAnswer("down", [], "хаб не подключён")
        try:
            if not self._token:
                await self._login()
            try:
                return HubAnswer("ok", await self._get_systems())
            except PermissionError:
                self._token = ""
                await self._login()
                return HubAnswer("ok", await self._get_systems())
        except PermissionError as exc:
            return HubAnswer("rejected", [], str(exc))
        except Exception as exc:
            logger.info("beszel: хаб не ответил: %s", exc)
            return HubAnswer("down", [], str(exc))


def info(system: dict) -> dict:
    """
    Поле info у сервера. Хаб кладёт туда либо объект, либо строку с JSON —
    зависит от версии, поэтому разбираем оба вида и никогда не падаем: пустой
    словарь честнее исключения, из-за которого молчал бы весь опрос.
    """
    raw = (system or {}).get("info")
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw:
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {}
        except ValueError:
            return {}
    return {}
