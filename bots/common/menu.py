"""
Корневой роутер объединённого бота: выбор раздела и сводный экран.

Подключается ПЕРВЫМ, до роутеров telemt и xui. Порядок важен: aiogram отдаёт
событие первому подошедшему обработчику, и здесь объявлен свой /start —
иначе сработал бы /start из telemt-части и показал бы клавиатуру одного
раздела вместо корневой.
"""

import logging

from aiogram import Bot, F, Router, types
from aiogram.filters import Command, StateFilter
from aiogram.fsm.context import FSMContext
from aiogram.types import BotCommand

from common import keyboards as kb

router = Router(name="menu")

COMMANDS = [
    BotCommand(command="start", description="🏠 главное меню"),
    BotCommand(command="summary", description="ℹ️ сводка по всему"),
]

WELCOME = (
    "🤖 <b>Объединённый бот</b>\n\n"
    "Выберите раздел кнопками внизу:\n"
    "• <b>Telemt</b> — статистика панели, история подключений, карта\n"
    "• <b>3x-ui</b> — статусы панелей и управление ими\n"
    "• <b>Сводка</b> — всё сразу, без переключения"
)


@router.message(Command("start", "menu"))
async def cmd_start(message: types.Message, state: FSMContext):
    await state.clear()
    await message.answer(WELCOME, reply_markup=kb.root_keyboard())


@router.message(StateFilter(None), F.text == kb.BTN_BACK)
async def go_root(message: types.Message):
    await message.answer("🏠 Главное меню", reply_markup=kb.root_keyboard())


@router.message(StateFilter(None), F.text == kb.BTN_TELEMT_SECTION)
async def go_telemt(message: types.Message):
    await message.answer("✈️ Раздел Telemt", reply_markup=kb.telemt_keyboard())


@router.message(StateFilter(None), F.text == kb.BTN_XUI_SECTION)
async def go_xui(message: types.Message):
    # Импорт внутри функции: список панелей берётся из xui-части, а тянуть её
    # на уровне модуля незачем — корневой роутер используется только вместе с ней.
    from xui.app import main_keyboard

    await message.answer("🎛 Раздел 3x-ui", reply_markup=await main_keyboard())


@router.message(StateFilter(None), Command("summary"))
@router.message(StateFilter(None), F.text == kb.BTN_SUMMARY)
async def show_summary(message: types.Message, bot: Bot):
    """
    Сводка: общий статус панелей 3x-ui плюс статистика Telemt.
    Ровно то, ради чего боты объединялись — оба ответа одним нажатием.
    """
    await message.answer("🔄 Собираю сводку...")

    # Каждая часть отправляется отдельно и независимо: если одна подсистема
    # недоступна, вторая всё равно должна показаться.
    from xui.api import get_all_servers_status_rich
    from xui.app import send_rich_or_fallback

    try:
        await send_rich_or_fallback(bot, message.chat.id, await get_all_servers_status_rich())
    except Exception as e:
        logging.error(f"Сводка: не удалось получить статус панелей 3x-ui: {e}")
        await message.answer("⚠️ Не удалось получить статус панелей 3x-ui.")

    from telemt.handlers.common import cmd_status

    try:
        await cmd_status(message)
    except Exception as e:
        logging.error(f"Сводка: не удалось получить статистику Telemt: {e}")
        await message.answer("⚠️ Не удалось получить статистику Telemt.")
