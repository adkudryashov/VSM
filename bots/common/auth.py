"""
Ограничение доступа. Один middleware на все три точки входа.

Чужие запросы игнорируются молча — как это было в 3xui-боте. Прежний ответ
telemt-бота «⛔ У вас нет доступа» подтверждал постороннему, что бот
существует и кем-то используется; для инструмента управления VPN это лишнее.

Регистрируется как outer_middleware: отсекает чужих до разбора фильтров,
не тратя работу на подбор обработчика.
"""

from typing import Any, Awaitable, Callable, Dict

from aiogram import BaseMiddleware
from aiogram.types import TelegramObject

from config import settings


class AuthMiddleware(BaseMiddleware):
    async def __call__(
        self,
        handler: Callable[[TelegramObject, Dict[str, Any]], Awaitable[Any]],
        event: TelegramObject,
        data: Dict[str, Any],
    ) -> Any:
        user = data.get("event_from_user")
        if user is None or user.id not in settings.ADMIN_IDS:
            return None
        return await handler(event, data)
