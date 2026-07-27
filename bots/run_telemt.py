#!/usr/bin/env python3
"""Точка входа отдельного telemt-бота."""
import asyncio

from aiogram.types import BotCommand

from common.runner import run
from config import settings
from telemt import app as telemt


async def main():
    await run(
        token=settings.TELEMT_BOT_TOKEN,
        token_name="TELEMT_BOT_TOKEN",
        routers=telemt.ROUTERS,
        commands=[BotCommand(command="start", description="🤖 приветствие и справка")] + telemt.COMMANDS,
        on_setup=telemt.setup,
        on_shutdown=telemt.shutdown,
        tasks=[telemt.collect_ips_periodically],
    )


if __name__ == "__main__":
    asyncio.run(main())
