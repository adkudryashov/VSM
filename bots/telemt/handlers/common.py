from telemt.utils.helpers import send_long_message, send_rich_or_fallback                                                                                                                                      
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
                                                                                                                                                                                 
def format_uptime(seconds: float) -> str:                                                                                                                                        
    if not seconds: return "0м"                                                                                                                                                  
    weeks = int(seconds // (7 * 24 * 3600))                                                                                                                                      
    seconds %= (7 * 24 * 3600)                                                                                                                                                   
    days = int(seconds // (24 * 3600))                                                                                                                                           
    seconds %= (24 * 3600)                                                                                                                                                       
    hours = int(seconds // 3600)                                                                                                                                                 
    seconds %= 3600                                                                                                                                                              
    minutes = int(seconds // 60)                                                                                                                                                 
    parts = []                                                                                                                                                                   
    if weeks > 0: parts.append(f"{weeks}н")                                                                                                                                      
    if days > 0: parts.append(f"{days}д")                                                                                                                                        
    if hours > 0: parts.append(f"{hours}ч")                                                                                                                                      
    if minutes > 0 or not parts: parts.append(f"{minutes}м")                                                                                                                     
    return ' '.join(parts)                                                                                                                                                       
                                                                                                                                                                                 
def format_connections(value: int) -> str:                                                                                                                                       
    if value < 1000: return str(value)                                                                                                                                           
    elif value < 1_000_000: return f"{value/1000:.1f}k" if value % 1000 != 0 else f"{value//1000}k"                                                                              
    else: return f"{value/1_000_000:.1f}M"                                                                                                                                       
                                                                                                                                                                                 
def format_traffic(bytes_val: int) -> str:                                                                                                                                       
    if bytes_val < 1024 * 1024: return f"{bytes_val / 1024:.1f} KB"                                                                                                              
    elif bytes_val < 1024 * 1024 * 1024: return f"{bytes_val / (1024 * 1024):.1f} MB"                                                                                            
    else: return f"{bytes_val / (1024 * 1024 * 1024):.2f} GB"                                                                                                                    
                                                                                                                                                                                 
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
                                                                                                                                                                                 
@router.message(Command("status"))                                                                                                                                               
async def cmd_status(message: types.Message):                                                                                                                                    
    try:                                                                                                                                                                         
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
        version_text = f"v{current_version} ({'актуальная' if latest_version == current_version else f'доступна v{latest_version}'})"                                            
                                                                                                                                                                                 
        text = (
            f"📊 {get_server_name()}\n\n"
            f"🔹 Статус:\n"
            f"• Аптайм: {format_uptime(summary_data['uptime_seconds'])}\n"
            f"• Трафик: {format_traffic(total_traffic)}\n"
            f"• Версия: {version_text}\n\n"
            f"🔹 Сетевая активность:\n"
            f"🌐 Активных IP: {total_active_ips}\n"
            f"🌐 Всего соединений: {format_connections(connections_total)}\n"
            f"┗━ ✅ Успешных: {good_connections} ({success_percent:.2f}%)\n"
            f"┗━ ⚠️ Сбои: {connections_bad} ({bad_percent:.2f}%)"
        )
        # Один экран в две колонки вместо двух таблиц одна под другой.
        # colspan в HTML-режиме проверен ответом sendRichMessage: сервер
        # возвращает заголовки как две ячейки с colspan=2.
        rich_html = (
            f"<h2>{html.escape(get_server_name())}</h2>"
            f"<table>"
            f"<tr><th colspan=\"2\">Статус</th><th colspan=\"2\">Сетевая активность</th></tr>"
            f"<tr><td>Аптайм</td><td>{html.escape(format_uptime(summary_data['uptime_seconds']))}</td>"
            f"<td>Всего соединений</td><td>{html.escape(format_connections(connections_total))}</td></tr>"
            f"<tr><td>Трафик</td><td>{html.escape(format_traffic(total_traffic))}</td>"
            f"<td>🟢 Успешных</td><td>{good_connections} ({success_percent:.2f}%)</td></tr>"
            f"<tr><td>Активные IP</td><td>{total_active_ips}</td>"
            f"<td>🔴 Сбои</td><td>{connections_bad} ({bad_percent:.2f}%)</td></tr>"
            # Версия вынесена вниз во всю ширину: строка длинная и в узкой
            # ячейке переносится, а пары к ней в правой колонке всё равно нет.
            f"<tr><td colspan=\"4\">Версия: {html.escape(version_text)}</td></tr>"
            f"</table>"
        )
        await send_rich_or_fallback(message, rich_html, text)
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
