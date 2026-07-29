import asyncio
import html
import logging
import sqlite3
import math
from datetime import datetime, timedelta
from collections import defaultdict

from aiogram import Router, F, types
from aiogram.filters import Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.filters.callback_data import CallbackData
from aiogram.exceptions import TelegramBadRequest

from telemt.utils.geo import country_flag, get_geoip_readers
from telemt.utils.helpers import send_long_message, send_rich_or_fallback, edit_rich_or_fallback, format_traffic
from telemt.api.client import TelemtAPIClient
from config import settings

router = Router()
api_client = TelemtAPIClient()
logger = logging.getLogger(__name__)

DB_PATH = settings.IP_HISTORY_DB
ITEMS_PER_PAGE = 10

class ReportCb(CallbackData, prefix="log"):
    action: str
    user: str = ""
    page: int = 0

def format_minutes(total_minutes: int) -> str:
    if total_minutes < 60:
        return f"{total_minutes} мин"
    hours = total_minutes // 60
    minutes = total_minutes % 60
    if hours < 24:
        return f"{hours} ч {minutes} мин"
    days = hours // 24
    hours = hours % 24
    return f"{days} дн {hours} ч {minutes} мин"

def to_moscow_time(raw_time_str: str) -> str:
    try:
        clean_str = raw_time_str.replace("T", " ")[:16]
        dt_utc = datetime.strptime(clean_str, "%Y-%m-%d %H:%M")
        dt_moscow = dt_utc + timedelta(hours=3)
        return dt_moscow.strftime("%Y-%m-%d %H:%M")
    except Exception:
        return raw_time_str.replace("T", " ")[:16]

def _sync_fetch_summary_rows():
    """Блокирующий SQLite-запрос — выполняется в отдельном потоке через asyncio.to_thread."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute("SELECT username, COUNT(DISTINCT ip) as ip_count FROM ip_log GROUP BY username")
    rows = cursor.fetchall()
    conn.close()
    return rows

async def build_summary_data():
    """
    Возвращает (rich_html, fallback_text, markup) либо (None, plain_text, None),
    если данных нет вообще.
    """
    traffic_map = defaultdict(int)
    try:
        api_users = await api_client.users()
        for u in api_users:
            uname = u.get("username") or u.get("name")
            if uname:
                traffic_map[uname] = int(u.get("total_octets") or 0)
    except Exception as api_err:
        logger.error(f"Ошибка получения трафика из API: {api_err}")

    db_rows = await asyncio.to_thread(_sync_fetch_summary_rows)

    if not db_rows:
        return None, "⚠️ Таблица ip_log пуста.", None

    users_data = []
    for row in db_rows:
        uname = row["username"]
        ip_count = row["ip_count"]
        traffic = traffic_map.get(uname, 0)
        users_data.append({"username": uname, "ip_count": ip_count, "traffic": traffic})

    users_data.sort(key=lambda x: x["traffic"], reverse=True)

    fallback_lines = ["📊 <b>ИСТОРИЯ ПОДКЛЮЧЕНИЙ (СВОДКА)</b>", "────────────────────────\n"]
    rich_rows = []
    kb = []
    for u in users_data:
        disp_name = f"@{u['username']}" if u['username'] and u['username'] != "Unknown" else "Неизвестный"
        fallback_lines.append(f"👤 <b>{disp_name}</b> | 📱 {u['ip_count']} IP | 💾 {format_traffic(u['traffic'])}")
        rich_rows.append(
            f"<tr><td>{html.escape(disp_name)}</td><td>{u['ip_count']}</td>"
            f"<td>{html.escape(format_traffic(u['traffic']))}</td></tr>"
        )
        kb.append([InlineKeyboardButton(
            text=f"👤 {disp_name}",
            callback_data=ReportCb(action="detail", user=u['username'], page=0).pack()
        )])

    fallback_lines.append("\n<i>Выберите пользователя ниже для просмотра детального лога.</i>")
    markup = InlineKeyboardMarkup(inline_keyboard=kb)

    rich_html = (
        "<h2>История подключений (сводка)</h2>"
        "<table><tr><th>Пользователь</th><th>IP</th><th>Трафик</th></tr>"
        + "".join(rich_rows) + "</table>"
        "<p>Выберите пользователя ниже для просмотра детального лога.</p>"
    )

    return rich_html, "\n".join(fallback_lines), markup


@router.message(Command("user_report", "geo_report"))
async def cmd_user_report(message: types.Message):
    try:
        rich_html, fallback_text, markup = await build_summary_data()
        if rich_html is None:
            await send_long_message(message, fallback_text)
        else:
            await send_rich_or_fallback(message, rich_html, fallback_text, reply_markup=markup)
    except Exception as e:
        await message.answer(f"❌ Ошибка хэндлера: {html.escape(str(e))}")

@router.callback_query(ReportCb.filter(F.action == "summary"))
async def cq_summary(call: types.CallbackQuery, callback_data: ReportCb):
    try:
        rich_html, fallback_text, markup = await build_summary_data()
        if rich_html is None:
            await call.message.edit_text(fallback_text, parse_mode="HTML")
        else:
            await edit_rich_or_fallback(call.message, rich_html, fallback_text, reply_markup=markup)
    except TelegramBadRequest:
        pass  # Игнорируем ошибку "Message is not modified"
    finally:
        await call.answer()

def _sync_fetch_detail_rows(user: str, page: int):
    """Блокирующий SQLite + GeoIP доступ — выполняется в отдельном потоке через asyncio.to_thread."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute("SELECT COUNT(*) FROM ip_log WHERE username = ?", (user,))
    total_records = cursor.fetchone()[0]

    total_pages = math.ceil(total_records / ITEMS_PER_PAGE) if total_records > 0 else 1
    page = max(0, min(page, total_pages - 1))  # Защита от выхода за пределы
    offset = page * ITEMS_PER_PAGE

    cursor.execute(
        "SELECT ip, first_seen, last_seen, count FROM ip_log WHERE username = ? ORDER BY last_seen DESC LIMIT ? OFFSET ?",
        (user, ITEMS_PER_PAGE, offset)
    )
    rows = cursor.fetchall()
    conn.close()

    reader_city, reader_asn = get_geoip_readers()

    geo_rows = []
    for row in rows:
        ip = row["ip"]
        count = row["count"] or 1
        last_seen = to_moscow_time(str(row["last_seen"]))
        geo_string = "🏳️ Локальный / Неизвестный"

        if reader_city and reader_asn:
            try:
                city_rec = reader_city.city(ip)
                c_code = city_rec.country.iso_code or "??"
                flag = country_flag(c_code) if c_code != "??" else "🏳️"
                city_name = city_rec.city.names.get('ru') or city_rec.city.name or ""
                asn_rec = reader_asn.asn(ip)
                asn_org = asn_rec.autonomous_system_organization or f"AS{asn_rec.autonomous_system_number}"

                geo_parts = [f"{flag} {c_code}"]
                if city_name: geo_parts.append(city_name)
                if asn_org: geo_parts.append(f"({asn_org})")
                geo_string = ", ".join(geo_parts)
            except Exception:
                geo_string = f"🏳️ {ip}"

        geo_rows.append((ip, geo_string, last_seen, count))

    return total_records, total_pages, page, geo_rows

@router.callback_query(ReportCb.filter(F.action == "detail"))
async def cq_detail(call: types.CallbackQuery, callback_data: ReportCb):
    user = callback_data.user
    page = callback_data.page

    total_records, total_pages, page, geo_rows = await asyncio.to_thread(
        _sync_fetch_detail_rows, user, page
    )

    disp_name = f"@{user}" if user and user != "Unknown" else "Неизвестного пользователя"

    fallback_lines = [f"📊 <b>Детальный лог IP для {disp_name}</b>", f"<i>Всего записей: {total_records}</i>", "────────────────────────\n"]
    rich_rows = []
    for ip, geo_string, last_seen, count in geo_rows:
        fallback_lines.append(f"🌐 <code>{ip:<15}</code> ── {html.escape(geo_string)}")
        fallback_lines.append(f"┗━ 🕒 {last_seen} | ⌛️ {format_minutes(count)}\n")
        rich_rows.append(
            f"<tr><td>{html.escape(ip)}</td><td>{html.escape(geo_string)}</td>"
            f"<td>{html.escape(last_seen)} | {html.escape(format_minutes(count))}</td></tr>"
        )

    rich_html = (
        f"<h2>Детальный лог IP для {html.escape(disp_name)}</h2>"
        f"<p>Всего записей: {total_records}</p>"
        f"<table><tr><th>IP</th><th>Гео</th><th>Активность</th></tr>"
        + "".join(rich_rows) + "</table>"
    )
    fallback_text = "\n".join(fallback_lines)

    # Сборка кнопок пагинации
    nav_buttons = []
    if page > 0:
        nav_buttons.append(InlineKeyboardButton(text="⬅️ Назад", callback_data=ReportCb(action="detail", user=user, page=page-1).pack()))
    
    nav_buttons.append(InlineKeyboardButton(text=f"{page + 1} / {total_pages}", callback_data="noop"))
    
    if page < total_pages - 1:
        nav_buttons.append(InlineKeyboardButton(text="Вперед ➡️", callback_data=ReportCb(action="detail", user=user, page=page+1).pack()))

    kb = [nav_buttons, [InlineKeyboardButton(text="↩️ К списку пользователей", callback_data=ReportCb(action="summary", user="", page=0).pack())]]
    markup = InlineKeyboardMarkup(inline_keyboard=kb)

    try:
        await edit_rich_or_fallback(call.message, rich_html, fallback_text, reply_markup=markup)
    except TelegramBadRequest:
        pass # Игнорируем, если текст не изменился (например, при двойном клике)
    finally:
        await call.answer()

@router.callback_query(F.data == "noop")
async def cq_noop(call: types.CallbackQuery):
    await call.answer()
