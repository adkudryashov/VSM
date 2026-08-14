"""
Сторож: живая карточка и команды /watch, /check, /mute, /unmute.

Имя /watch, а не /status: /status в этом боте давно занят общей статистикой, и
переопределять его значило бы менять привычное поведение ради нового раздела.
По той же причине кнопка называется «Сторож», а не «Статус».

Команды оставлены рядом с кнопками намеренно. Кнопки удобнее, но их не
процитируешь в переписке и не наберёшь по памяти, а привычка к /mute у того,
кто уже ей пользовался, никуда не денется.
"""

import re

from aiogram import F, Router, types
from aiogram.filters import Command, StateFilter

from common import keyboards as kb
from config import settings
from telemt.utils.helpers import send_long_message
from telemt.watchdog import card
from telemt.watchdog.monitor import watchdog

router = Router()


def _disabled_note() -> str:
    return ("🛡 Сторож выключен.\n\n"
            "Включить: меню VSM → Telegram-боты → Сторож.")


async def _show_card(message: types.Message) -> None:
    """
    Показывает карточку внизу чата.

    Именно с переносом: команду набирают тогда, когда карточка уехала вверх и
    её не видно. Правка на месте в этом случае выглядит как «ничего не
    произошло» — человек попросил статус и не получил ответа.
    """
    if not settings.WATCHDOG_ENABLED:
        await send_long_message(message, _disabled_note())
        return
    await card.refresh(message.bot, relocate=True, force=True)


@router.message(Command("watch"))
async def cmd_watch(message: types.Message):
    await _show_card(message)


@router.message(StateFilter(None), F.text == kb.BTN_TELEMT_WATCH)
async def btn_watch(message: types.Message):
    """
    StateFilter(None) обязателен, как у остальных кнопок в panel.py: посреди
    пошагового диалога нажатие не должно уводить из него. Ввод в этот момент
    отсекается отдельно — по MENU_BUTTONS, куда подпись попала автоматически,
    потому что добавлена в TELEMT_BUTTONS.
    """
    await _show_card(message)


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
    await card.refresh(message.bot, force=True)


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
    await card.refresh(message.bot, force=True)


@router.message(Command("unmute"))
async def cmd_unmute(message: types.Message):
    await send_long_message(message, watchdog.unmute())
    await card.refresh(message.bot, force=True)


# --- Кнопки под карточкой ---------------------------------------------------
# Посторонний сюда не дойдёт: AuthMiddleware отсекает чужих и на сообщениях, и
# на нажатиях кнопок (common/runner.py).

@router.callback_query(F.data == "wd:refresh")
async def cb_refresh(callback: types.CallbackQuery):
    await callback.answer()
    await card.refresh(callback.bot, force=True)


@router.callback_query(F.data == "wd:check")
async def cb_check(callback: types.CallbackQuery):
    if not settings.RU_CHECK_ENABLED:
        await callback.answer("Проверка из РФ выключена в меню VSM.", show_alert=True)
        return
    blocked = watchdog.manual_block_reason()
    if blocked:
        # Всплывающим окном, а не правкой карточки: это ответ на конкретное
        # нажатие, и в состоянии сервера он ничего не меняет.
        await callback.answer(re.sub(r"<[^>]+>", "", blocked), show_alert=True)
        return
    # Отвечаем сразу: Telegram ждёт отклика на нажатие несколько секунд, а
    # проверка идёт до минуты. Результат приедет правкой карточки.
    await callback.answer("Запускаю проверку, до минуты…")
    card.spawn_check(callback.bot)


@router.callback_query(F.data == "wd:mute")
async def cb_mute_menu(callback: types.CallbackQuery):
    await callback.answer()
    try:
        await callback.message.edit_reply_markup(reply_markup=card.mute_keyboard())
    except Exception:
        # Карточку могли удалить — тогда просто нарисуем заново.
        await card.refresh(callback.bot, relocate=True, force=True)


@router.callback_query(F.data.startswith("wd:mute:"))
async def cb_mute_set(callback: types.CallbackQuery):
    minutes = int(callback.data.rsplit(":", 1)[1])
    watchdog.mute(minutes)
    await callback.answer("Тревоги заглушены.")
    await card.refresh(callback.bot, force=True)


@router.callback_query(F.data == "wd:unmute")
async def cb_unmute(callback: types.CallbackQuery):
    watchdog.unmute()
    await callback.answer("Тревоги снова включены.")
    await card.refresh(callback.bot, force=True)
