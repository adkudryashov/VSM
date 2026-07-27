#!/usr/bin/env python3
"""Точка входа отдельного 3xui-бота."""
import asyncio

from aiogram import Router, types
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.types import BotCommand

from common.runner import run
from config import settings
from xui import app as xui

# /start у отдельного бота показывает клавиатуру раздела сразу:
# уровня выше нет, выбирать нечего.
start_router = Router(name="xui_start")


@start_router.message(Command("start"))
async def cmd_start(message: types.Message, state: FSMContext):
    await state.clear()
    await message.answer("👋 Бот запущен.", reply_markup=await xui.main_keyboard())


async def main():
    await run(
        token=settings.XUI_BOT_TOKEN,
        token_name="XUI_BOT_TOKEN",
        routers=[start_router, xui.router],
        commands=[BotCommand(command="start", description="🎛 меню панелей")],
        on_setup=xui.setup,
        tasks=[xui.monitor_servers_loop],
    )


if __name__ == "__main__":
    asyncio.run(main())
