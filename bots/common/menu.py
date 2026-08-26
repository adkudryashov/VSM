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

    ОДНИМ СООБЩЕНИЕМ, когда обе части ответили.
    ------------------------------------------
    Прежде их было три: заглушка «Собираю сводку…», таблица панелей и таблица
    telemt. Заглушку никто не удалял, и каждый вызов оставлял в переписке
    лишнюю строку навсегда — за месяц их набиралось столько же, сколько самих
    сводок. Вместо неё индикатор «печатает»: он исчезает сам и не оставляет
    следа.

    Раздельная отправка была не прихотью, а защитой: отказ одной подсистемы не
    должен уносить вторую. Защита сохранена — просто перевёрнута. Сначала обе
    части СОБИРАЮТСЯ, и если обе получились, уходит одно сообщение; если
    отвалилась любая, шлём то, что есть, и отдельным сообщением говорим, чего
    не хватает.
    """
    from xui.api import get_all_servers_status_parts
    from xui.app import send_rich_or_fallback as send_xui
    from telemt.handlers.common import build_status_parts, get_server_name
    from telemt.utils.helpers import send_long_message
    import html

    # Индикатор вместо сообщения. Сбор идёт секунды, и без единого признака
    # работы нажатие выглядит как промах.
    try:
        await bot.send_chat_action(message.chat.id, "typing")
    except Exception:
        pass  # Индикатор — вежливость, а не механизм: его отказ ничего не значит.

    panels_rich = panels_plain = None
    try:
        panels_rich, panels_plain = await get_all_servers_status_parts()
    except Exception as e:
        logging.error(f"Сводка: не удалось получить статус панелей 3x-ui: {e}")

    telemt_rich = telemt_plain = None
    try:
        telemt_rich, telemt_plain = await build_status_parts()
    except Exception as e:
        logging.error(f"Сводка: не удалось получить статистику Telemt: {e}")

    if panels_rich is None and telemt_rich is None:
        await message.answer("⚠️ Ни одна часть сводки не собралась. Подробности в журнале бота.")
        return

    # Заголовки третьего уровня под одним общим: два <h2> подряд читались как
    # два несвязанных отчёта.
    rich = ["<h2>Сводка</h2>"]
    plain = ["📋 <b>Сводка</b>"]
    if panels_rich is not None:
        rich.append("<h3>Панели 3x-ui</h3>" + panels_rich)
        plain.append("\n📊 <b>Панели 3x-ui</b>\n" + panels_plain)
    if telemt_rich is not None:
        name = get_server_name()
        rich.append(f"<h3>telemt · {html.escape(name)}</h3>" + telemt_rich)
        plain.append(f"\n🛫 <b>telemt · {html.escape(name)}</b>\n" + telemt_plain)

    await send_xui(bot, message.chat.id, "".join(rich), "\n".join(plain))

    missing = []
    if panels_rich is None:
        missing.append("статус панелей 3x-ui")
    if telemt_rich is None:
        missing.append("статистику telemt")
    if missing:
        await send_long_message(message, "⚠️ Не удалось получить " + " и ".join(missing) + ".")
