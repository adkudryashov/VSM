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

from common.auth import AuthMiddleware
from config import settings


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

    # outer: отсекает чужих до разбора фильтров
    auth = AuthMiddleware()
    dp.message.outer_middleware(auth)
    dp.callback_query.outer_middleware(auth)

    for router in routers:
        dp.include_router(router)

    await bot.delete_my_commands()
    await bot.set_my_commands(commands)

    if on_shutdown:
        dp.shutdown.register(on_shutdown)

    for task in tasks:
        asyncio.create_task(task(bot))

    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)
