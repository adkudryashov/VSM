#!/usr/bin/env python3
"""
Точка входа объединённого бота: telemt и 3x-ui в одном.

Роутер меню подключается ПЕРВЫМ — его /start показывает корневую клавиатуру
выбора раздела. Иначе сработал бы /start из telemt-части.
"""
import asyncio

from common import menu
from common.runner import run
from config import settings
from telemt import app as telemt
from xui import app as xui

# В объединённом боте у раздела 3x-ui есть кнопка «Назад» на верхний уровень.
xui.WITH_BACK = True


async def setup():
    await telemt.setup()
    await xui.setup()


async def main():
    await run(
        token=settings.COMBINED_BOT_TOKEN,
        token_name="COMBINED_BOT_TOKEN",
        routers=[menu.router] + telemt.ROUTERS + [xui.router],
        commands=menu.COMMANDS + telemt.COMMANDS,
        on_setup=setup,
        on_shutdown=telemt.shutdown,
        tasks=[telemt.collect_ips_periodically, xui.monitor_servers_loop],
    )


if __name__ == "__main__":
    asyncio.run(main())
