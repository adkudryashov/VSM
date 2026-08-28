"""
Очистка истории подключений, которую собирает сам бот.

ЧТО ЭТО И ЧЕГО ЭТО НЕ ЕСТЬ. Здесь удаляются НАШИ данные: таблица ip_log в
bots/data/ip_history.db, куда цикл сбора пишет пары «пользователь + адрес», и
построенная из неё карта. К самому telemt раздел не прикасается: его
пользователями и конфигом занимаются с компьютера, где есть веб-панель. Решение
владельца 28.08.2026, разбор — в docs/DECISIONS.md.

ПОЧЕМУ ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ДОПИСКА В reports.py. Там чтение, здесь
единственное в боте удаление по нажатию кнопки. Смешивать чтение с
безвозвратной записью в одном модуле — верный способ однажды перепутать.

ГЛАВНОЕ, ЧТО НАДО ЗНАТЬ ПРО ЭТИ ДАННЫЕ: ip_history.db НЕ входит в резервную
копию. Удаление окончательно, восстановить неоткуда.
"""

import hashlib
import logging
import os

from aiogram import F, Router, types
from aiogram.filters import Command, StateFilter

from config import settings
from telemt.utils import storage
from telemt.utils.helpers import send_long_message

router = Router()
logger = logging.getLogger(__name__)

MAP_HTML_PATH = settings.MAP_HTML_PATH


def _uhash(username: str) -> str:
    """
    Короткий отпечаток имени для callback_data.

    ИМЯ В КНОПКУ КЛАСТЬ НЕЛЬЗЯ. В callback_data всего 64 байта, а кириллица
    тратит два на символ. В меню X-UI на этом уже обожглись: длинное имя ломало
    не свою строку, а всю инлайн-клавиатуру целиком, и понять это по виду было
    невозможно. Имена пользователей telemt задаёт кто угодно — здесь ждали бы те
    же грабли.

    Двенадцати шестнадцатеричных знаков хватает: имён в логе единицы, а цена
    совпадения — удаление не того пользователя, поэтому при нажатии совпадение
    ещё раз проверяется по живому списку.
    """
    return hashlib.sha256(username.encode("utf-8")).hexdigest()[:12]


async def _resolve(uhash: str) -> str | None:
    """Найти имя по отпечатку в ТЕКУЩЕМ списке. Нет — значит список устарел."""
    for name, _count in await storage.history_usernames():
        if _uhash(name) == uhash:
            return name
    return None


def _drop_map() -> bool:
    """
    Убрать построенную карту. True — файл был и удалён.

    Карта удаляется ВСЕГДА, даже при чистке одного пользователя. Это снимок,
    лежащий на диске и отдаваемый снаружи по секретному пути: стереть строки и
    оставить файл значит удалить данные, которые продолжают показываться.

    Именно удалить, а не пересобрать: folium может не запуститься — на приёмке
    27.08.2026 так и было, процессор без SSE4.2, — и тогда старый файл остался
    бы навсегда. Новая карта строится по /map.
    """
    try:
        if os.path.exists(MAP_HTML_PATH):
            os.remove(MAP_HTML_PATH)
            return True
    except OSError as exc:
        logger.warning("не удалось убрать карту %s: %s", MAP_HTML_PATH, exc)
    return False


def _stats_text(st: dict) -> str:
    if not st["rows"]:
        return (
            "🧹 <b>Очистка истории</b>\n\n"
            "История пуста — чистить нечего.\n\n"
            "<i>Сюда попадают адреса, с которых подключались пользователи. "
            "Записи появятся после первых подключений.</i>"
        )

    period = ""
    if st["first"] and st["last"]:
        period = f"\n🕒 Период: {st['first']} — {st['last']}"

    have_map = os.path.exists(MAP_HTML_PATH)
    return (
        "🧹 <b>Очистка истории</b>\n\n"
        f"📋 Записей: {st['rows']}\n"
        f"🌐 Адресов: {st['ips']}\n"
        f"👥 Имён: {st['users']}"
        f"{period}\n"
        f"🗺 Карта: {'построена' if have_map else 'не построена'}\n\n"
        "<i>Удаление необратимо: эта база не входит в резервные копии. "
        "Вместе с записями убирается и построенная карта — иначе удалённые "
        "адреса продолжали бы показываться в ней.</i>"
    )


def _menu_keyboard(st: dict) -> types.InlineKeyboardMarkup | None:
    """
    Кнопки удаления. Пусто — None.

    Кнопка, которая всегда отвечает «нечего удалять», хуже её отсутствия. То же
    правило применено к «Зондам» и «Проверить» в карточке сторожа.
    """
    if not st["rows"]:
        return None
    rows = [[types.InlineKeyboardButton(text="🗑 Стереть всё", callback_data="cln:all")]]
    if st["users"]:
        rows.append([types.InlineKeyboardButton(text="👤 Стереть по пользователю",
                                                callback_data="cln:pick")])
    return types.InlineKeyboardMarkup(inline_keyboard=rows)


async def show_cleanup(message: types.Message):
    st = await storage.history_stats()
    await send_long_message(message, _stats_text(st), reply_markup=_menu_keyboard(st))


@router.message(Command("cleanup"))
async def cmd_cleanup(message: types.Message):
    await show_cleanup(message)


@router.message(StateFilter(None), F.text == "🧹 Очистка")
async def btn_cleanup(message: types.Message):
    await show_cleanup(message)


@router.callback_query(F.data == "cln:pick")
async def pick_user(call: types.CallbackQuery):
    users = await storage.history_usernames()
    if not users:
        await call.answer("История уже пуста", show_alert=True)
        return
    rows = [
        [types.InlineKeyboardButton(text=f"🗑 {name} · {count}",
                                    callback_data=f"cln:u:{_uhash(name)}")]
        for name, count in users
    ]
    rows.append([types.InlineKeyboardButton(text="⬅ Отмена", callback_data="cln:cancel")])
    await call.message.edit_text(
        "👤 <b>Чью историю стереть?</b>\n\n"
        "<i>Рядом с именем — сколько записей у него в логе.</i>",
        parse_mode="HTML",
        reply_markup=types.InlineKeyboardMarkup(inline_keyboard=rows),
    )
    await call.answer()


@router.callback_query(F.data == "cln:all")
async def confirm_all(call: types.CallbackQuery):
    st = await storage.history_stats()
    if not st["rows"]:
        await call.answer("История уже пуста", show_alert=True)
        return
    await call.message.edit_text(
        "❗️ <b>Стереть всю историю?</b>\n\n"
        f"Исчезнет: {st['rows']} записей, {st['ips']} адресов, {st['users']} имён"
        f"{', и построенная карта' if os.path.exists(MAP_HTML_PATH) else ''}.\n\n"
        "<i>Восстановить неоткуда: эта база не входит в резервные копии.</i>",
        parse_mode="HTML",
        reply_markup=types.InlineKeyboardMarkup(inline_keyboard=[[
            types.InlineKeyboardButton(text="🗑 Да, стереть", callback_data="cln:go:all"),
            types.InlineKeyboardButton(text="⬅ Отмена", callback_data="cln:cancel"),
        ]]),
    )
    await call.answer()


@router.callback_query(F.data.startswith("cln:u:"))
async def confirm_user(call: types.CallbackQuery):
    uhash = call.data.split(":", 2)[2]
    name = await _resolve(uhash)
    if name is None:
        await call.answer("Список устарел — откройте очистку заново", show_alert=True)
        return
    await call.message.edit_text(
        f"❗️ <b>Стереть историю пользователя?</b>\n\n"
        f"Имя: <code>{name}</code>\n\n"
        "<i>Карта будет убрана вместе с записями: иначе удалённые адреса "
        "остались бы видны на ней. Построить заново — /map.</i>",
        parse_mode="HTML",
        reply_markup=types.InlineKeyboardMarkup(inline_keyboard=[[
            types.InlineKeyboardButton(text="🗑 Да, стереть", callback_data=f"cln:go:u:{uhash}"),
            types.InlineKeyboardButton(text="⬅ Отмена", callback_data="cln:cancel"),
        ]]),
    )
    await call.answer()


@router.callback_query(F.data == "cln:cancel")
async def cancel(call: types.CallbackQuery):
    st = await storage.history_stats()
    await call.message.edit_text(_stats_text(st), parse_mode="HTML",
                                 reply_markup=_menu_keyboard(st))
    await call.answer("Отменено")


@router.callback_query(F.data.startswith("cln:go:"))
async def do_purge(call: types.CallbackQuery):
    target = call.data.split(":", 2)[2]
    name = None
    if target.startswith("u:"):
        name = await _resolve(target[2:])
        if name is None:
            await call.answer("Список устарел — откройте очистку заново", show_alert=True)
            return

    # Ошибку не глушим: «готово» при неудачном удалении — худшее, что здесь
    # можно напечатать, потому что человек уйдёт уверенным, что данных больше
    # нет.
    try:
        removed = await storage.purge_history(name)
    except Exception as exc:                       # noqa: BLE001 — показать причину
        logger.exception("очистка истории не удалась")
        await call.message.edit_text(f"❌ Не удалось стереть: {exc}")
        await call.answer()
        return

    map_gone = _drop_map()

    # Считаем ПОСЛЕ удаления, а не берём показанное ранее: между показом и
    # нажатием цикл сбора мог добавить запись, и отчёт по старым числам был бы
    # рассказом о том, чего мы не проверяли.
    st = await storage.history_stats()
    what = "вся история" if name is None else f"история пользователя {name}"
    await call.message.edit_text(
        f"✅ Стёрто: {what} — {removed} записей."
        + ("\n🗺 Карта убрана." if map_gone else "")
        + f"\n\n📋 Осталось записей: {st['rows']}",
        parse_mode="HTML",
    )
    await call.answer()
