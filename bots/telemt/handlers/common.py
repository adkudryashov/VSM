from telemt.utils.helpers import (send_long_message, send_rich_or_fallback,
                                  format_traffic, format_percent,
                                  format_uptime, format_connections)                                                                                                                                      
import asyncio
import html                                                                                                                                                                   
import httpx                                                                                                                                                                     
import tomli                                                                                                                                                                     
from pathlib import Path                                                                                                                                                         
from aiogram import Router, types                                                                                                                                                
from aiogram.filters import Command                                                                                                                                              
from telemt.api.client import TelemtAPIClient                                                                                                                                           
from config import settings
from telemt.keyboards.inline import get_main_keyboard                                                                                                                                                      
                                                                                                                                                                                 
router = Router()                                                                                                                                                                
api = TelemtAPIClient()                                                                                                                                                          
                                                                                                                                                                                 
def get_server_name() -> str:                                                                                                                                                    
    config_path = Path("/etc/telemt/telemt.toml")                                                                                                                                
    if config_path.is_file():                                                                                                                                                    
        try:                                                                                                                                                                     
            with open(config_path, "rb") as f:                                                                                                                                   
                data = tomli.load(f)                                                                                                                                             
            domain = data.get("censorship", {}).get("tls_domain", "").strip()                                                                                                    
            if domain: return domain                                                                                                                                             
        except Exception: pass                                                                                                                                                   
    return settings.SERVER_NAME                                                                                                                                                  
                                                                                                                                                                                 
async def get_latest_version() -> str | None:                                                                                                                                    
    if not settings.CHECK_VERSION: return None                                                                                                                                   
    try:                                                                                                                                                                         
        async with httpx.AsyncClient(timeout=5) as client:                                                                                                                       
            resp = await client.get("https://api.github.com/repos/telemt/telemt/releases/latest")                                                                                
            if resp.status_code == 200: return resp.json().get("tag_name", "").lstrip("v")                                                                                       
    except Exception: pass                                                                                                                                                       
    return None                                                                                                                                                                  
                                                                                                                                                                                 
@router.message(Command("start", "help"))                                                                                                                                        
async def cmd_start(message: types.Message):                                                                                                                                     
    text = ("🤖 Telemt Control Bot\n\n📊 /status\n👥 /usersstatus\n📋 /usagereport\n👤 /userinfo\n✍️ /writers\n🌍 /dcs\n🔄 /upstreams\n⚙️ /runtime\n🏥 /health")                   
    await send_long_message(message, text, reply_markup=get_main_keyboard())
                                                                                                                                                                                 
# Один словарь значков на все ответы бота.
#
# Кружок — СОСТОЯНИЕ с градациями, ✅/⚠️/🚨 — события и тревоги. Прежде 🟢 и ✅
# встречались в одной сводке в одинаковом смысле, и глаз перестраивался на
# каждой строке.
OK = "🟢"
WARN = "🟡"
BAD = "🔴"


def _quality_mark(success_percent: float) -> str:
    """
    Значок у доли успешных соединений.

    Прежде 🟢 и 🔴 стояли подписями строк «Успешных» и «Сбои» — то есть были
    украшением: зелёный горел и при 40% успеха, красный светил при нуле сбоев.
    Значок обязан что-то означать, иначе он мешает искать глазами тот, который
    означает.
    """
    if success_percent >= 99:
        return OK
    if success_percent >= 95:
        return WARN
    return BAD


def _version_line(current: str, latest: str) -> str:
    """
    Версия одной строкой, читаемой раньше, чем прочитана.

    Было: «v1.2.3 (актуальная)» либо «v1.2.3 (доступна v1.3.0)» — оба варианта
    приходится дочитывать до скобки. Стрелка говорит то же самое короче, а
    цвет виден первым.
    """
    if not latest or latest == current:
        return f"{OK} v{current} · актуальная"
    return f"{WARN} v{current} → v{latest}"


async def build_status_parts() -> tuple[str, str]:
    """
    Собирает (rich_html, fallback_text) БЕЗ верхнего заголовка.

    Заголовок ставит вызывающий: у отдельной команды /status он свой, а в
    общей сводке обе части живут под одним заголовком, и два конкурирующих
    <h2> подряд читались как два несвязанных отчёта.
    """
    summary, users, sys_info, latest_version = await asyncio.gather(
        api.summary(), api.users(), api.system_info(), get_latest_version()
    )
    summary_data, sys_data = summary["data"], sys_info["data"]
    total_active_ips = sum(u.get("active_unique_ips", 0) for u in users)
    total_traffic = sum(u.get("total_octets", 0) for u in users)

    connections_total = summary_data['connections_total']
    connections_bad = summary_data['connections_bad_total']
    bad_percent = (connections_bad / connections_total * 100) if connections_total > 0 else 0
    success_percent = 100 - bad_percent if connections_total > 0 else 100
    good_connections = max(0, connections_total - connections_bad)

    current_version = sys_data.get('version', 'неизвестно')
    version_text = _version_line(current_version, latest_version)
    mark = _quality_mark(success_percent)

    text = (
        f"🔹 Статус:\n"
        f"• Аптайм: {format_uptime(summary_data['uptime_seconds'])}\n"
        f"• Трафик: {format_traffic(total_traffic)}\n"
        f"• Версия: {version_text}\n\n"
        f"🔹 Сетевая активность:\n"
        f"🌐 Активных IP: {total_active_ips}\n"
        f"🌐 Всего соединений: {format_connections(connections_total)}\n"
        f"┗━ {mark} Успешных: {format_connections(good_connections)} ({format_percent(success_percent)})\n"
        f"┗━ Сбои: {format_connections(connections_bad)} ({format_percent(bad_percent)})"
    )
    # Один экран в две колонки вместо двух таблиц одна под другой.
    # colspan в HTML-режиме проверен ответом sendRichMessage: сервер
    # возвращает заголовки как две ячейки с colspan=2.
    rich_html = (
        f"<table>"
        f"<tr><th colspan=\"2\">Статус</th><th colspan=\"2\">Сетевая активность</th></tr>"
        f"<tr><td>Аптайм</td><td>{html.escape(format_uptime(summary_data['uptime_seconds']))}</td>"
        f"<td>Всего соединений</td><td>{html.escape(format_connections(connections_total))}</td></tr>"
        f"<tr><td>Трафик</td><td>{html.escape(format_traffic(total_traffic))}</td>"
        f"<td>{mark} Успешных</td><td>{html.escape(format_connections(good_connections))} ({format_percent(success_percent)})</td></tr>"
        f"<tr><td>Активные IP</td><td>{total_active_ips}</td>"
        f"<td>Сбои</td><td>{html.escape(format_connections(connections_bad))} ({format_percent(bad_percent)})</td></tr>"
        # Версия вынесена вниз во всю ширину: строка длинная и в узкой
        # ячейке переносится, а пары к ней в правой колонке всё равно нет.
        f"<tr><td colspan=\"4\">Версия: {html.escape(version_text)}</td></tr>"
        f"</table>"
    )
    return rich_html, text


@router.message(Command("status"))
async def cmd_status(message: types.Message):
    try:
        rich_html, text = await build_status_parts()
        name = get_server_name()
        await send_rich_or_fallback(
            message,
            f"<h2>{html.escape(name)}</h2>" + rich_html,
            f"📊 {name}\n\n" + text,
        )
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: {e}")

@router.message(Command("health"))                                                                                                                                               
async def cmd_health(message: types.Message):                                                                                                                                    
    try:                                                                                                                                                                         
        health = await api.health()                                                                                                                                              
        status = health["data"]["status"]                                                                                                                                        
        ro = health["data"]["read_only"]                                                                                                                                         
        await send_long_message(message, f"🏥 API здоров: {'✅' if status == 'ok' else '❌'} {status}\nRead-only: {'🔒' if ro else '🔓'}")                                       
    except Exception as e:                                                                                                                                                       
        await send_long_message(message, f"❌ Ошибка: {e}")
