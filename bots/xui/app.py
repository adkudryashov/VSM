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
from datetime import date, datetime

import aiohttp
from aiogram import Bot, F, Router, types
from aiogram.filters import StateFilter
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import BotCommand, InputRichMessage
from aiogram.utils.keyboard import InlineKeyboardBuilder

from common import datepicker as dp
from common import keyboards as kb
from config import settings
from xui.api import clean_base_url, get_all_servers_status_rich, get_detailed_panel_report
from xui.database import (
    add_new_panel,
    delete_panel_by_name,
    get_all_panels,
    init_db,
    update_panel_expiry,
)

router = Router(name="xui")

COMMANDS = [
    BotCommand(command="panels", description="🎛 панели 3x-ui"),
]


class AddPanelStates(StatesGroup):
    waiting_for_name = State()
    waiting_for_url = State()
    waiting_for_token = State()
    waiting_for_date = State()
    waiting_for_manual_date = State()


class EditPanelStates(StatesGroup):
    """Правка срока у заведённой панели. Шага ввода реквизитов тут нет."""
    waiting_for_date = State()
    waiting_for_manual_date = State()


# Оба сценария заканчиваются одним и тем же виджетом даты, поэтому стражи,
# обработчики календаря и запись в базу у них общие.
DATE_FLOW = StateFilter(AddPanelStates, EditPanelStates)


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


async def edit_inline_keyboard():
    """
    Имя панели идёт в callback_data сырым префиксом, а не через CallbackData:
    у фабрики разделитель «:», и имя с двоеточием сломало бы разбор.
    Длину имени ограничивает process_name — здесь 64 байта уже гарантированно хватает.
    """
    builder = InlineKeyboardBuilder()
    panels = await get_all_panels()
    for name, config in panels.items():
        builder.add(types.InlineKeyboardButton(
            text=f"✏️ {name} — {dp.to_display(config.get('expiry_date'))}",
            callback_data=f"edit_{name}",
        ))
    builder.add(types.InlineKeyboardButton(text="🚫 Отмена", callback_data="cancel_edit"))
    builder.adjust(1)
    return builder.as_markup()


# Предупреждение о недоступности Rich Message — один раз за жизнь процесса.
# Причина у всех откатов одна, и повторять её на каждую команду — шум.
_rich_warned = False


async def send_rich_or_fallback(bot: Bot, chat_id: int, html_content: str,
                                fallback_text: str | None = None):
    """
    Отправляет Rich Message; при ошибке API — откатывается на обычный текст.

    fallback_text — ГОТОВЫЙ запасной вариант, собранный тем же кодом, что и
    богатый. Раньше его не было, и запасным путём служило срезание тегов
    регуляркой: таблица превращалась в слипшуюся строку значений без единого
    разделителя, где «онлайн 3» и «4.1 GB» стояли вплотную. Читать это
    невозможно, а появляется оно ровно тогда, когда что-то уже сломалось.
    Срезание оставлено только на случай, когда запасного текста не передали.
    """
    global _rich_warned
    try:
        await bot.send_rich_message(
            chat_id=chat_id,
            rich_message=InputRichMessage(html=html_content),
        )
    except Exception as e:
        logging.warning("Rich Message не отправился, показываю обычным текстом: %s", e)
        if not _rich_warned:
            _rich_warned = True
            await bot.send_message(
                chat_id=chat_id,
                text="⚠️ Rich Message недоступен — показываю обычным текстом.\n"
                     "Дальше повторять не буду, причина в журнале бота.",
            )
        if fallback_text is not None:
            await bot.send_message(chat_id=chat_id, text=fallback_text, parse_mode="HTML")
        else:
            plain = re.sub(r"<[^>]+>", " ", html_content)
            await bot.send_message(chat_id=chat_id, text=html.escape(plain))


# ---------------------------------------------------------------------------
# ПОШАГОВЫЕ СЦЕНАРИИ: ДОБАВЛЕНИЕ ПАНЕЛИ И ПРАВКА СРОКА
#
# Эти два обработчика объявлены ПЕРВЫМИ и с фильтром по состоянию намеренно.
# Обработчики шагов ловят любой текст, поэтому нажатие любой кнопки меню
# посреди диалога иначе уехало бы в имя или токен панели.
# ---------------------------------------------------------------------------

@router.message(DATE_FLOW, F.text == kb.BTN_CANCEL)
async def cancel_panel_dialog(message: types.Message, state: FSMContext):
    await state.clear()
    await message.answer("🚫 Отменено.", reply_markup=kb.xui_manage_keyboard())


@router.message(DATE_FLOW, F.func(lambda m: kb.is_menu_button(m.text)))
async def busy_panel_dialog(message: types.Message):
    await message.answer(
        "⏳ Сейчас идёт пошаговый ввод. Заверши его или нажми «❌ Отмена».",
        reply_markup=kb.cancel_keyboard(),
    )


@router.message(StateFilter(None), F.text == kb.BTN_XUI_ADD)
async def start_add_panel(message: types.Message, state: FSMContext):
    await message.answer("Введите имя панели:", reply_markup=kb.cancel_keyboard())
    await state.set_state(AddPanelStates.waiting_for_name)


@router.message(AddPanelStates.waiting_for_name)
async def process_name(message: types.Message, state: FSMContext):
    name = message.text.strip()
    # Имя уезжает в callback_data кнопок удаления и правки, а там всего
    # 64 байта. Кириллица — два байта на символ, так что без этой проверки
    # длинное имя ломает не свою строку, а всю инлайн-клавиатуру целиком.
    if len(name.encode()) > 48:
        await message.answer("❌ Слишком длинное имя. Не больше 48 байт (24 символа кириллицей):")
        return
    await state.update_data(name=name)
    await message.answer("Введите URL (с префиксом http/https):")
    await state.set_state(AddPanelStates.waiting_for_url)


@router.message(AddPanelStates.waiting_for_url)
async def process_url(message: types.Message, state: FSMContext):
    await state.update_data(base_url=message.text.strip().rstrip("/"))
    await message.answer("Введите API Token:")
    await state.set_state(AddPanelStates.waiting_for_token)


@router.message(AddPanelStates.waiting_for_token)
async def process_token(message: types.Message, state: FSMContext):
    await state.update_data(token=message.text.strip(), mode="add")
    await state.set_state(AddPanelStates.waiting_for_date)
    await ask_for_date(message, state, date.today(), "Панель почти готова.")


# ---------------------------------------------------------------------------
# ВИДЖЕТ ДАТЫ. Общий для добавления и правки: расходятся они только в самом
# конце, на записи в базу.
# ---------------------------------------------------------------------------

async def ask_for_date(message: types.Message, state: FSMContext, base: date, title: str):
    """
    Единственная точка показа виджета. message_id кладём в состояние: по нему
    колбэки отличат живое меню от старого календаря, оставшегося в истории
    чата после рестарта бота или другого сценария.
    """
    sent = await message.answer(
        f"{title}\n📅 Выберите дату окончания подписки (сейчас {dp.to_display(base)}):",
        reply_markup=dp.presets_keyboard(base),
    )
    await state.update_data(base=dp.to_iso(base), picker_msg_id=sent.message_id)


async def _finish_date(message: types.Message, state: FSMContext, chosen: date):
    """
    Общий финал: в базу всегда уходит ISO, потому что так её читают фоновые
    алерты о сроке и таблица общего статуса. Формат ввода их не касается.
    """
    data = await state.get_data()
    await state.clear()
    shown = dp.to_display(chosen)
    stale = "\n⚠️ Дата уже прошла." if chosen < date.today() else ""

    if data.get("mode") == "edit":
        ok = await update_panel_expiry(data["name"], dp.to_iso(chosen))
        text = (f"✅ Срок панели «{html.escape(data['name'])}» теперь {shown}{stale}"
                if ok else "❌ Панель не найдена — возможно, её успели удалить.")
    else:
        ok = await add_new_panel(data["name"], data["base_url"], data["token"],
                                 dp.to_iso(chosen))
        text = (f"✅ Панель добавлена, срок до {shown}{stale}"
                if ok else "❌ Ошибка: имя уже занято.")

    await message.answer(text, reply_markup=kb.xui_manage_keyboard())


@router.message(StateFilter(AddPanelStates.waiting_for_date,
                            EditPanelStates.waiting_for_date))
async def nudge_use_widget(message: types.Message):
    """Пока открыт календарь, обычный текст не является датой — подсказываем."""
    await message.answer("👆 Выберите дату кнопками выше или нажмите «✏️ Ввести вручную».")


@router.message(StateFilter(AddPanelStates.waiting_for_manual_date,
                            EditPanelStates.waiting_for_manual_date))
async def process_manual_date(message: types.Message, state: FSMContext):
    chosen = dp.parse_manual(message.text)
    if chosen is None:
        await message.answer(dp.MANUAL_ERROR)
        return
    await _finish_date(message, state, chosen)


# Объявлен раньше общего обработчика: иначе клики по пустым ячейкам сетки
# и по подписи месяца провалились бы в основную цепочку ветвлений.
@router.callback_query(DATE_FLOW, dp.DateCb.filter(F.action == "noop"))
async def date_noop(callback: types.CallbackQuery):
    await callback.answer()


@router.callback_query(DATE_FLOW, dp.DateCb.filter())
async def date_widget(callback: types.CallbackQuery, callback_data: dp.DateCb,
                      state: FSMContext):
    data = await state.get_data()
    # MemoryStorage не переживает рестарт, а старый календарь остаётся в
    # истории чата. Без этой проверки клик по нему записал бы дату не туда.
    if not data.get("mode") or callback.message.message_id != data.get("picker_msg_id"):
        await callback.answer(dp.STALE_ANSWER, show_alert=True)
        return

    base = datetime.strptime(data["base"], "%Y-%m-%d").date()
    action = callback_data.action

    if action == "cancel":
        await state.clear()
        await callback.message.edit_text("🚫 Отменено.")
        await callback.message.answer("🛠 Управление панелями",
                                      reply_markup=kb.xui_manage_keyboard())
    elif action in ("calendar", "nav"):
        await callback.message.edit_reply_markup(
            reply_markup=dp.calendar_keyboard(callback_data.year, callback_data.month))
    elif action == "presets":
        await callback.message.edit_reply_markup(reply_markup=dp.presets_keyboard(base))
    elif action == "manual":
        target = (AddPanelStates.waiting_for_manual_date if data["mode"] == "add"
                  else EditPanelStates.waiting_for_manual_date)
        await state.set_state(target)
        await callback.message.edit_reply_markup(reply_markup=None)
        await callback.message.answer(dp.MANUAL_PROMPT, reply_markup=kb.cancel_keyboard())
    elif action in ("preset", "day"):
        # Числа приходят из callback_data, то есть снаружи. Своя клавиатура
        # присылает только существующие даты, но подпись кнопки можно подделать
        # и прислать 31 февраля или ключ пресета, которого нет, — без разбора
        # исключения обработчик падал бы, а пользователь видел зависший
        # календарь без единого объяснения.
        try:
            chosen = (dp.shift(base, callback_data.value) if action == "preset"
                      else date(callback_data.year, callback_data.month, callback_data.day))
        except (ValueError, KeyError):
            await callback.answer(dp.STALE_ANSWER, show_alert=True)
            return
        await callback.message.edit_reply_markup(reply_markup=None)
        await _finish_date(callback.message, state, chosen)

    await callback.answer()


# ---------------------------------------------------------------------------
# ОБЫЧНЫЕ КНОПКИ. StateFilter(None) — чтобы не перебивать пошаговый диалог.
# ---------------------------------------------------------------------------

@router.message(StateFilter(None), F.text == kb.BTN_XUI_STATUS)
async def show_status(message: types.Message, bot: Bot):
    await message.answer("🔄 Загрузка...")
    await send_rich_or_fallback(bot, message.chat.id, await get_all_servers_status_rich())


@router.message(StateFilter(None), F.text == kb.BTN_XUI_MANAGE)
async def show_manage_menu(message: types.Message):
    await message.answer("🛠 Управление панелями", reply_markup=kb.xui_manage_keyboard())


@router.message(StateFilter(None), F.text == kb.BTN_XUI_MANAGE_BACK)
async def leave_manage_menu(message: types.Message):
    # main_keyboard() сама учитывает WITH_BACK, поэтому в объединённом боте
    # ниже появится «⬅️ Назад», а в отдельном — нет.
    await message.answer("🎛 Панели 3x-ui", reply_markup=await main_keyboard())


@router.message(StateFilter(None), F.text.startswith(kb.PANEL_PREFIX))
async def show_panel_details(message: types.Message, bot: Bot):
    panel_name = message.text[len(kb.PANEL_PREFIX):]
    panels = await get_all_panels()
    if panel_name in panels:
        html_content = await get_detailed_panel_report(panel_name, panels[panel_name])
        await send_rich_or_fallback(bot, message.chat.id, html_content)


@router.message(StateFilter(None), F.text == kb.BTN_XUI_DELETE)
async def cmd_delete_panel_list(message: types.Message):
    await message.answer("Выберите панель:", reply_markup=await delete_inline_keyboard())


@router.callback_query(F.data.startswith("del_"))
async def process_delete_callback(callback: types.CallbackQuery):
    panel_name = callback.data[4:]
    if await delete_panel_by_name(panel_name):
        await callback.message.edit_text(f"🗑️ Удалено: {html.escape(panel_name)}")
        await callback.message.answer("Меню:", reply_markup=kb.xui_manage_keyboard())
    await callback.answer()


@router.callback_query(F.data == "cancel_delete")
async def process_cancel_delete(callback: types.CallbackQuery):
    await callback.message.edit_text("🚫 Удаление отменено.")
    await callback.message.answer("Меню:", reply_markup=kb.xui_manage_keyboard())
    await callback.answer()


@router.message(StateFilter(None), F.text == kb.BTN_XUI_EDIT_DATE)
async def cmd_edit_date_list(message: types.Message):
    await message.answer("Какой панели меняем дату?", reply_markup=await edit_inline_keyboard())


@router.callback_query(StateFilter(None), F.data.startswith("edit_"))
async def process_edit_pick(callback: types.CallbackQuery, state: FSMContext):
    panel_name = callback.data[5:]
    panels = await get_all_panels()
    if panel_name not in panels:
        await callback.answer("Панель уже удалена.", show_alert=True)
        return

    # Пресеты считаем от текущего срока, а не от сегодня: «+1 год» должен
    # продлевать подписку, а не обнулять уже оплаченный остаток. У просроченной
    # панели точка отсчёта — сегодня, иначе продление уедет в прошлое.
    base = date.today()
    current = panels[panel_name].get("expiry_date")
    if current:
        try:
            base = max(base, datetime.strptime(current, "%Y-%m-%d").date())
        except ValueError:
            pass

    await callback.message.edit_text(f"✏️ Панель: {html.escape(panel_name)}")
    await state.set_state(EditPanelStates.waiting_for_date)
    await state.update_data(name=panel_name, mode="edit")
    await ask_for_date(callback.message, state, base, f"Панель «{html.escape(panel_name)}».")
    await callback.answer()


@router.callback_query(F.data == "cancel_edit")
async def process_cancel_edit(callback: types.CallbackQuery, state: FSMContext):
    await state.clear()
    await callback.message.edit_text("🚫 Правка отменена.")
    await callback.message.answer("Меню:", reply_markup=kb.xui_manage_keyboard())
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
