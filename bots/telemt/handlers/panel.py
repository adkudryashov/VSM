from telemt.utils.helpers import send_long_message
import logging
from aiogram import Router, types, F
from aiogram.filters import Command, StateFilter
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton

from telemt.handlers.common import cmd_status, cmd_health
from telemt.handlers.users import cmd_usersstatus, cmd_userinfo
from telemt.handlers.stats import cmd_writers, cmd_dcs, cmd_runtime
from telemt.handlers.reports import cmd_user_report  # Исправлено имя функции
from telemt.handlers.metrics import cmd_metrics
from telemt.handlers.map import cmd_map
from telemt.handlers.cleanup import show_cleanup
from config import settings

router = Router()
logger = logging.getLogger(__name__)

def panel_keyboard():
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(text="📊 Статус", callback_data="cmd:status"),
                InlineKeyboardButton(text="⚙️ Метрики", callback_data="cmd:metrics"),
            ],
            [
                InlineKeyboardButton(text="👥 Активные IP", callback_data="cmd:usersstatus"),
                InlineKeyboardButton(text="📋 Лог IP", callback_data="cmd:usagereport"),
            ],
            [
                InlineKeyboardButton(text="🗺 Web-карта", callback_data="cmd:map"),
            ],
            # Очистка есть и на постоянной клавиатуре. Держим в обеих: панели
            # почти повторяют друг друга, и кнопка, которая есть на одной и нет
            # на другой, — расхождение, которое некому заметить.
            [
                InlineKeyboardButton(text="🧹 Очистка", callback_data="cmd:cleanup"),
            ],
        ]
    )

@router.message(Command("panel"))
async def cmd_panel(message: types.Message):
    # Используем наш хелпер
    await send_long_message(message, "🎛 Панель управления Telemt", reply_markup=panel_keyboard())

# --- Обработчики кнопок постоянной клавиатуры (keyboards/inline.py) ---

@router.message(StateFilter(None), F.text == "📊 Статус")
async def btn_status(message: types.Message):
    await cmd_status(message)

@router.message(StateFilter(None), F.text == "⚙️ Метрики")
async def btn_metrics(message: types.Message):
    await cmd_metrics(message)

@router.message(StateFilter(None), F.text == "👥 Активные IP")
async def btn_usersstatus(message: types.Message):
    await cmd_usersstatus(message)

@router.message(StateFilter(None), F.text == "📋 Лог IP")
async def btn_user_report(message: types.Message):
    await cmd_user_report(message)

@router.message(StateFilter(None), F.text == "🗺 Карта")
async def btn_map(message: types.Message):
    await cmd_map(message)

@router.callback_query(lambda c: c.data and c.data.startswith("cmd:"))
async def process_panel_callback(callback: types.CallbackQuery):
    command = callback.data.split(":", 1)[1]

    simple_handlers = {
        "status": cmd_status,
        "metrics": cmd_metrics,
        "usersstatus": cmd_usersstatus,
        "usagereport": cmd_user_report,  # Исправлено имя функции
        "map": cmd_map,
        "cleanup": show_cleanup,
    }

    if command not in simple_handlers:
        await callback.answer(f"Неизвестная команда: {command}", show_alert=True)
        return

    await callback.answer()

    try:
        # Убираем старую клавиатуру
        try:
            await callback.message.edit_reply_markup(reply_markup=None)
        except Exception:
            pass

        # Вызываем хэндлер, передавая сообщение из колбэка
        await simple_handlers[command](callback.message)

        # Отправляем новую панель через наш хелпер
        await send_long_message(callback.message, "🎛 Панель управления Telemt", reply_markup=panel_keyboard())

    except Exception as e:
        logger.error(f"Ошибка выполнения команды {command} в панели: {e}")
        # Ошибку тоже отправляем через наш хелпер
        await send_long_message(callback.message, f"❌ Ошибка: {str(e)[:100]}")
