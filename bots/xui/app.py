"""
Сборка 3x-ui-части: роутер, список команд и фоновый мониторинг панелей.

Раньше это был монолитный bot.py с обработчиками прямо на Dispatcher —
такой файл нельзя включить в другого бота. Теперь это Router, который
подключается и в отдельного, и в объединённого бота.
"""

import asyncio
import html
import logging
import re
from datetime import datetime

import aiohttp
from aiogram import Bot, F, Router, types
from aiogram.filters import StateFilter
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import BotCommand, InputRichMessage
from aiogram.utils.keyboard import InlineKeyboardBuilder

from common import keyboards as kb
from config import settings
from xui.api import clean_base_url, get_all_servers_status_rich, get_detailed_panel_report
from xui.database import add_new_panel, delete_panel_by_name, get_all_panels, init_db

router = Router(name="xui")

COMMANDS = [
    BotCommand(command="panels", description="🎛 панели 3x-ui"),
]


class AddPanelStates(StatesGroup):
    waiting_for_name = State()
    waiting_for_url = State()
    waiting_for_token = State()
    waiting_for_date = State()


# В объединённом боте клавиатура раздела содержит «Назад», в отдельном — нет.
# Флаг ставит точка входа при сборке.
WITH_BACK = False


async def main_keyboard():
    panels = await get_all_panels()
    return kb.xui_keyboard(panels.keys(), with_back=WITH_BACK)


async def delete_inline_keyboard():
    builder = InlineKeyboardBuilder()
    panels = await get_all_panels()
    for name in panels.keys():
        builder.add(types.InlineKeyboardButton(text=f"❌ {name}", callback_data=f"del_{name}"))
    builder.add(types.InlineKeyboardButton(text="🚫 Отмена", callback_data="cancel_delete"))
    builder.adjust(1)
    return builder.as_markup()


async def send_rich_or_fallback(bot: Bot, chat_id: int, html_content: str):
    """
    Отправляет Rich Message; если API вернёт ошибку — откатывается на обычный
    текст, чтобы бот не падал и было видно, что именно пошло не так.
    """
    try:
        await bot.send_rich_message(
            chat_id=chat_id,
            rich_message=InputRichMessage(html=html_content),
        )
    except Exception as e:
        await bot.send_message(
            chat_id=chat_id,
            text=f"⚠️ Rich Message не отправился, показываю как обычный текст.\n"
                 f"Ошибка: {html.escape(str(e))}",
        )
        plain = re.sub(r"<[^>]+>", " ", html_content)
        await bot.send_message(chat_id=chat_id, text=html.escape(plain))


# ---------------------------------------------------------------------------
# ПОШАГОВОЕ ДОБАВЛЕНИЕ ПАНЕЛИ
#
# Эти два обработчика объявлены ПЕРВЫМИ и с фильтром по состоянию намеренно.
# Обработчики шагов ловят любой текст, поэтому нажатие любой кнопки меню
# посреди диалога иначе уехало бы в имя или токен панели.
# ---------------------------------------------------------------------------

@router.message(StateFilter(AddPanelStates), F.text == kb.BTN_CANCEL)
async def cancel_add_panel(message: types.Message, state: FSMContext):
    await state.clear()
    await message.answer("🚫 Добавление отменено.", reply_markup=await main_keyboard())


@router.message(StateFilter(AddPanelStates), F.func(lambda m: kb.is_menu_button(m.text)))
async def busy_adding_panel(message: types.Message):
    await message.answer(
        "⏳ Сейчас идёт добавление панели. Заверши ввод или нажми «❌ Отмена».",
        reply_markup=kb.cancel_keyboard(),
    )


@router.message(StateFilter(None), F.text == "➕ Добавить панель")
async def start_add_panel(message: types.Message, state: FSMContext):
    await message.answer("Введите имя панели:", reply_markup=kb.cancel_keyboard())
    await state.set_state(AddPanelStates.waiting_for_name)


@router.message(AddPanelStates.waiting_for_name)
async def process_name(message: types.Message, state: FSMContext):
    await state.update_data(name=message.text.strip())
    await message.answer("Введите URL (с префиксом http/https):")
    await state.set_state(AddPanelStates.waiting_for_url)


@router.message(AddPanelStates.waiting_for_url)
async def process_url(message: types.Message, state: FSMContext):
    await state.update_data(base_url=message.text.strip().rstrip("/"))
    await message.answer("Введите API Token:")
    await state.set_state(AddPanelStates.waiting_for_token)


@router.message(AddPanelStates.waiting_for_token)
async def process_token(message: types.Message, state: FSMContext):
    await state.update_data(token=message.text.strip())
    await message.answer("Введите дату окончания (ГГГГ-ММ-ДД):")
    await state.set_state(AddPanelStates.waiting_for_date)


@router.message(AddPanelStates.waiting_for_date)
async def process_date(message: types.Message, state: FSMContext):
    date_input = message.text.strip()
    try:
        datetime.strptime(date_input, "%Y-%m-%d")
    except ValueError:
        await message.answer("❌ Ошибка формата. Введите ГГГГ-ММ-ДД:")
        return

    data = await state.get_data()
    await state.clear()
    if await add_new_panel(data["name"], data["base_url"], data["token"], date_input):
        await message.answer("✅ Панель добавлена!", reply_markup=await main_keyboard())
    else:
        await message.answer("❌ Ошибка: имя уже занято.", reply_markup=await main_keyboard())


# ---------------------------------------------------------------------------
# ОБЫЧНЫЕ КНОПКИ. StateFilter(None) — чтобы не перебивать пошаговый диалог.
# ---------------------------------------------------------------------------

@router.message(StateFilter(None), F.text == "📊 Общий статус")
async def show_status(message: types.Message, bot: Bot):
    await message.answer("🔄 Загрузка...")
    await send_rich_or_fallback(bot, message.chat.id, await get_all_servers_status_rich())


@router.message(StateFilter(None), F.text.startswith(kb.PANEL_PREFIX))
async def show_panel_details(message: types.Message, bot: Bot):
    panel_name = message.text[len(kb.PANEL_PREFIX):]
    panels = await get_all_panels()
    if panel_name in panels:
        html_content = await get_detailed_panel_report(panel_name, panels[panel_name])
        await send_rich_or_fallback(bot, message.chat.id, html_content)


@router.message(StateFilter(None), F.text == "🗑️ Удалить панель")
async def cmd_delete_panel_list(message: types.Message):
    await message.answer("Выберите панель:", reply_markup=await delete_inline_keyboard())


@router.callback_query(F.data.startswith("del_"))
async def process_delete_callback(callback: types.CallbackQuery):
    panel_name = callback.data[4:]
    if await delete_panel_by_name(panel_name):
        await callback.message.edit_text(f"🗑️ Удалено: {html.escape(panel_name)}")
        await callback.message.answer("Меню:", reply_markup=await main_keyboard())
    await callback.answer()


@router.callback_query(F.data == "cancel_delete")
async def process_cancel_delete(callback: types.CallbackQuery):
    await callback.message.edit_text("🚫 Удаление отменено.")
    await callback.message.answer("Меню:", reply_markup=await main_keyboard())
    await callback.answer()


# ---------------------------------------------------------------------------
# ФОНОВЫЙ МОНИТОРИНГ
# ---------------------------------------------------------------------------

async def _notify_admins(bot: Bot, text: str):
    for admin_id in settings.ADMIN_IDS:
        try:
            await bot.send_message(chat_id=admin_id, text=text, parse_mode="HTML")
        except Exception as e:
            logging.warning(f"Не удалось отправить уведомление админу {admin_id}: {e}")


async def check_single_panel_status(base_url, headers):
    timeout = aiohttp.ClientTimeout(total=4.0)
    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(f"{base_url}/panel/api/server/status", headers=headers) as resp:
                if resp.status == 200:
                    json_data = await resp.json()
                    return True, json_data.get("obj", {}).get("cpu", 0)
    except Exception:
        pass
    return False, 0


async def monitor_servers_loop(bot: Bot):
    await asyncio.sleep(10)
    last_connection_status = {}
    failure_counters = {}
    last_date_check = None

    while True:
        try:
            panels = await get_all_panels()
            today = datetime.now().date()

            if last_date_check != today:
                last_date_check = today
                for name, config in panels.items():
                    exp_date_str = config.get("expiry_date")
                    if not exp_date_str:
                        continue
                    try:
                        exp_date = datetime.strptime(exp_date_str, "%Y-%m-%d").date()
                        days_left = (exp_date - today).days
                        if days_left in (7, 3, 1):
                            await _notify_admins(
                                bot,
                                f"📅 <b>Срок VPS {html.escape(name)} истекает!</b>\n"
                                f"Осталось: {days_left} дней.",
                            )
                    except ValueError:
                        logging.warning(f"Панель {name}: не разобрал дату '{exp_date_str}'")

            for name, config in panels.items():
                last_connection_status.setdefault(name, True)
                failure_counters.setdefault(name, 0)

                base_url = clean_base_url(config["base_url"])
                headers = {"Authorization": f"Bearer {config['token']}"}
                is_online, _cpu = await check_single_panel_status(base_url, headers)

                if not is_online:
                    failure_counters[name] += 1
                    if (failure_counters[name] >= settings.XUI_FAILURES_BEFORE_ALERT
                            and last_connection_status[name]):
                        last_connection_status[name] = False
                        await _notify_admins(bot, f"🚨 <b>ПАДЕНИЕ {html.escape(name)}!</b>")
                else:
                    if not last_connection_status[name]:
                        last_connection_status[name] = True
                        await _notify_admins(bot, f"🟢 <b>{html.escape(name)} СНОВА В СЕТИ!</b>")
                    failure_counters[name] = 0
        except Exception as e:
            logging.error(f"Ошибка цикла мониторинга панелей: {e}")

        await asyncio.sleep(settings.XUI_CHECK_INTERVAL_SECONDS)


async def setup():
    await init_db()
