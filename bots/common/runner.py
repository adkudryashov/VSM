"""
Общий запуск для всех трёх точек входа: отдельного telemt-бота,
отдельного 3xui-бота и объединённого.

Отличаются они только набором роутеров, команд и фоновых задач.
"""

import asyncio
import logging

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import BotCommandScopeChat

from common.auth import AuthMiddleware
from config import settings


async def _register_commands(bot: Bot, commands) -> None:
    """
    Подсказки команд — только в чатах администраторов.

    Посторонний, наткнувшийся на бота, не должен видеть даже списка команд:
    перечень вида «состояние датацентров», «карта подключений», «проверить
    доступность из РФ» сам по себе рассказывает, что за сервер за ним стоит.
    Отвечать чужому бот и раньше не стал бы — за это отвечает AuthMiddleware, —
    но список выдавался всем подряд.

    Пока администратор не написал боту ни разу, чата не существует, и Telegram
    отвечает отказом. Это не ошибка: подсказки встанут при следующем запуске,
    после первого /start. Общий список в этом случае НЕ ставим — иначе смысл
    ограничения теряется ровно в том случае, ради которого оно вводилось.

    Глобальный список снимается всегда: у тех, кто ставил бота прежней версией,
    он уже зарегистрирован, и без явного снятия остался бы висеть навсегда.
    """
    await bot.delete_my_commands()

    registered = 0
    for admin_id in settings.ADMIN_IDS:
        try:
            await bot.set_my_commands(commands, scope=BotCommandScopeChat(chat_id=admin_id))
            registered += 1
        except Exception as exc:
            logging.info("Команды для %s не зарегистрированы (%s) — встанут после /start",
                         admin_id, exc)
    if not registered:
        logging.warning("Подсказки команд не зарегистрированы ни для кого: "
                        "напишите боту /start и перезапустите его.")


async def run(*, token, token_name, routers, commands, on_setup=None, on_shutdown=None, tasks=()):
    logging.basicConfig(level=logging.INFO)

    # Понятная ошибка вместо невнятного отказа Telegram при пустом токене
    if not token:
        raise SystemExit(f"Не задан {token_name} — заполните bots/.env")
    if not settings.ADMIN_IDS:
        raise SystemExit("Не задан ADMIN_IDS — бот отвечал бы только пустому списку")

    if on_setup:
        await on_setup()

    # parse_mode=HTML: telemt-часть указывает его и явно, но так безопаснее,
    # а пользовательский текст в 3xui-части экранируется.
    bot = Bot(token=token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    dp = Dispatcher(storage=MemoryStorage())

    # Вешаем на dp.update — на общий поток, а не на отдельные его виды.
    #
    # Раньше стояло на dp.message и dp.callback_query. Обхода это не давало:
    # все обработчики бота ровно двух этих видов. Но наблюдателей у диспетчера
    # четырнадцать, и один добавленный @router.inline_query или
    # @router.my_chat_member открыл бы бота посторонним — молча, без единого
    # предупреждения, потому что проверка просто не вызвалась бы. Защита не
    # должна держаться на том, что кто-то помнит про этот список.
    #
    # Порядок безопасен: диспетчер регистрирует свою UserContextMiddleware в
    # __init__, то есть раньше нашей, и event_from_user к моменту проверки уже
    # заполнен. Проверено на aiogram 3.30.
    auth = AuthMiddleware()
    dp.update.outer_middleware(auth)

    for router in routers:
        dp.include_router(router)

    await _register_commands(bot, commands)

    if on_shutdown:
        dp.shutdown.register(on_shutdown)

    for task in tasks:
        asyncio.create_task(task(bot))

    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)
