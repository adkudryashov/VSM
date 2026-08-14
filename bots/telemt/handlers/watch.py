"""
Команды сторожа: /watch, /check, /mute, /unmute.

Имя /watch, а не /status: /status в этом боте давно занят общей статистикой, и
переопределять его значило бы менять привычное поведение ради нового раздела.
"""

import re

from aiogram import Router, types
from aiogram.filters import Command

from config import settings
from telemt.utils.helpers import send_long_message
from telemt.watchdog.monitor import watchdog

router = Router()


def _disabled_note() -> str:
    return ("🛡 Сторож выключен.\n\n"
            "Включить: меню VSM → Telegram-боты → Сторож.")


@router.message(Command("watch"))
async def cmd_watch(message: types.Message):
    if not settings.WATCHDOG_ENABLED:
        await send_long_message(message, _disabled_note())
        return
    await send_long_message(message, watchdog.render_status())


@router.message(Command("check"))
async def cmd_check(message: types.Message):
    if not settings.RU_CHECK_ENABLED:
        await send_long_message(
            message,
            "🇷🇺 Проверка доступности из РФ выключена.\n\n"
            "Она просит публичный сервис Globalping подключиться к вашему прокси "
            "с домашних адресов в России: к серверу пойдёт внешний трафик, а его "
            "адрес и порт уйдут в стороннее API. Включается осознанно — "
            "меню VSM → Telegram-боты → Сторож.",
        )
        return
    # Кулдаун и исчерпанный бюджет отвечают мгновенно — спрашиваем до того, как
    # пообещать запуск: иначе «запускаю проверку» и следом «нельзя».
    blocked = watchdog.manual_block_reason()
    if blocked:
        await send_long_message(message, blocked)
        return
    # Проверка идёт десятки секунд: без этой строки человек решит, что бот завис.
    await message.answer("🇷🇺 Запускаю проверку, это займёт до минуты…")
    await send_long_message(message, await watchdog.run_ru_check(message.bot, manual=True))


@router.message(Command("mute"))
async def cmd_mute(message: types.Message):
    """`/mute` — до отмены, `/mute 30` или `/mute 2h` — на срок."""
    arg = (message.text or "").partition(" ")[2].strip().lower()
    minutes = 0
    if arg:
        found = re.match(r"^(\d+)\s*([mhмч]?)", arg)
        if not found:
            await send_long_message(message, "Не понял срок. Примеры: /mute 30, /mute 2h, /mute")
            return
        minutes = int(found.group(1))
        if found.group(2) in ("h", "ч"):
            minutes *= 60
    await send_long_message(message, watchdog.mute(minutes))


@router.message(Command("unmute"))
async def cmd_unmute(message: types.Message):
    await send_long_message(message, watchdog.unmute())
