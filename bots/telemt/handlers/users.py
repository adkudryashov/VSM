from telemt.utils.helpers import collapse, send_long_message, send_rich_or_fallback
import asyncio
import html
from aiogram import Router, types
from aiogram.filters import Command, CommandObject
from telemt.api.client import TelemtAPIClient
from telemt.utils.geo import get_ip_info, country_flag

router = Router()
api = TelemtAPIClient()

MAX_CHUNK_CHARS = 3200      # запас под HTML-теги таблицы и форматирование одного сообщения
HUGE_USER_THRESHOLD = 3 * MAX_CHUNK_CHARS  # если блок одного пользователя больше — шлём его отдельно порциями

def _build_user_block(username: str, rows: list[tuple[str, str]]) -> tuple[str, str]:
    """
    Строит (block_html, block_plain) для одного пользователя — развёрнутый
    <details open> с таблицей IP/Гео внутри, и текстовый аналог для fallback.
    """
    if not rows:
        block_html = f"<details open><summary>👤 {html.escape(username)} (0)</summary><p>Нет активных IP.</p></details>"
        block_plain = f"👤 {html.escape(username)} (0)\n⚠️ Нет активных IP."
        return block_html, block_plain

    table_rows_html = "".join(f"<tr><td>{ip}</td><td>{geo}</td></tr>" for ip, geo in rows)
    block_html = (
        f"<details open><summary>👤 {html.escape(username)} ({len(rows)})</summary>"
        f"<table><tr><th>IP</th><th>Гео</th></tr>{table_rows_html}</table></details>"
    )
    # Заголовок с именем — снаружи цитаты, адреса — внутри. Свёрнутый блок
    # обязан отвечать на вопрос «чей это список», не раскрываясь.
    head = f"👤 <b>{html.escape(username)}</b> ({len(rows)})"
    body = "\n".join(f"🌐 <code>{ip:<15}</code> — {geo}" for ip, geo in rows)
    block_plain = collapse(body, head)
    return block_html, block_plain

async def _send_merged_blocks(message: types.Message, blocks: list[tuple[str, str]]):
    """
    Объединяет блоки пользователей в минимально возможное число сообщений
    (bin-packing по размеру), чтобы не отправлять одно сообщение на каждого
    пользователя. Первое сообщение получает заголовок "Активные IP".
    """
    if not blocks:
        return

    groups: list[list[tuple[str, str]]] = []
    current: list[tuple[str, str]] = []
    current_len = 0

    for block_html, block_plain in blocks:
        if current and current_len + len(block_html) > MAX_CHUNK_CHARS:
            groups.append(current)
            current, current_len = [], 0
        current.append((block_html, block_plain))
        current_len += len(block_html)
    if current:
        groups.append(current)

    for i, group in enumerate(groups):
        title_html = "<h2>Активные IP</h2>" if i == 0 else "<h3>Активные IP (продолжение)</h3>"
        title_plain = "👥 Активные IP\n" if i == 0 else "👥 Активные IP (продолжение)\n"
        html_content = title_html + "".join(b[0] for b in group)
        plain_content = title_plain + "\n\n".join(b[1] for b in group)
        await send_rich_or_fallback(message, html_content, plain_content)
        await asyncio.sleep(0.05)  # небольшая пауза — защита от flood-лимитов при многих сообщениях

async def _send_ip_table_chunks(message: types.Message, username: str, rows: list[tuple[str, str]]):
    """
    Для аномально больших пользователей (1000+ IP) — отправляет таблицу
    IP/Гео порциями отдельными сообщениями (без <details>, так как весь
    объём и так один пользователь на несколько сообщений).
    """
    header_html = f"<h3>👤 {html.escape(username)} ({len(rows)})</h3>"
    await send_rich_or_fallback(message, header_html, f"👤 {html.escape(username)} ({len(rows)})")

    table_rows: list[str] = []
    plain_lines: list[str] = []
    chunk_len = 0

    async def _flush():
        table_html = "<table><tr><th>IP</th><th>Гео</th></tr>" + "".join(table_rows) + "</table>"
        # Была обычная цитата — теперь раскрывающаяся: у таких пользователей
        # счёт адресов идёт на сотни, и порция занимает экран целиком.
        plain_fallback = collapse("\n".join(plain_lines))
        await send_rich_or_fallback(message, table_html, plain_fallback)
        await asyncio.sleep(0.05)

    for ip, geo in rows:
        row_html = f"<tr><td>{ip}</td><td>{geo}</td></tr>"
        plain_line = f"🌐 <code>{ip:<15}</code> — {geo}"
        if chunk_len + len(row_html) > MAX_CHUNK_CHARS and table_rows:
            await _flush()
            table_rows, plain_lines, chunk_len = [], [], 0
        table_rows.append(row_html)
        plain_lines.append(plain_line)
        chunk_len += len(row_html)

    if table_rows:
        await _flush()

@router.message(Command("usersstatus"))
async def cmd_usersstatus(message: types.Message):
    geo_map = {
        "Russia": "RU", "Moscow": "Москва",
        "USA": "US", "Germany": "DE", "Netherlands": "NL"
    }

    try:
        users = await api.users()
        if not users:
            await send_long_message(message, "Нет пользователей.")
            return

        blocks: list[tuple[str, str]] = []
        huge_users: list[tuple[str, list[tuple[str, str]]]] = []

        for user in users:
            username = user['username']
            ips = user.get('active_unique_ips_list', [])

            try:
                rows = []
                if ips:
                    geo_results = await asyncio.gather(*[get_ip_info(ip) for ip in ips], return_exceptions=True)
                    for ip, geo in zip(ips, geo_results):
                        if isinstance(geo, dict) and geo:
                            flag = country_flag(geo.get('countryCode', ''))
                            country_en = geo.get('country', 'Unknown')
                            city_en = geo.get('city', '')
                            isp = geo.get('isp', 'Unknown')

                            country = geo_map.get(country_en, country_en)
                            city = geo_map.get(city_en, city_en)

                            geo_str = html.escape(f"{flag} {country}, {city} ({isp})")
                        else:
                            geo_str = "❓ неизвестно"

                        rows.append((html.escape(ip), geo_str))

                block_html, block_plain = _build_user_block(username, rows)
                if len(block_html) > HUGE_USER_THRESHOLD:
                    huge_users.append((username, rows))
                else:
                    blocks.append((block_html, block_plain))
            except Exception as user_err:
                blocks.append((
                    f"<p>👤 {html.escape(username)} — ❌ ошибка вывода</p>",
                    f"👤 {username}\n❌ Ошибка вывода: {html.escape(str(user_err)[:100])}"
                ))

        await _send_merged_blocks(message, blocks)

        for username, rows in huge_users:
            await _send_ip_table_chunks(message, username, rows)

    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: <code>{str(e)[:100]}</code>")

@router.message(Command("userinfo"))
async def cmd_userinfo(message: types.Message, command: CommandObject):
    if not command.args:
        await send_long_message(message, "Использование: /userinfo <username>")
        return

    username = command.args.strip()
    try:
        info = await api.get_user(username)
        user = info["data"]
        text = (
            f"👤 <b>{user['username']}</b>\n"
            f"🔗 Соединений: {user['current_connections']}\n"
            f"📊 Трафик: {user['total_octets']} байт"
        )
        await send_long_message(message, text, )
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: <code>{e}</code>")
