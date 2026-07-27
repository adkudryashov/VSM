from telemt.utils.helpers import send_long_message
import asyncio
import os
import time
import logging
import folium
from folium.plugins import MarkerCluster
from aiogram import Router, types
from aiogram.filters import Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton, WebAppInfo
from aiogram.enums import ParseMode
import sqlite3
from telemt.utils.geo import country_flag, get_geoip_readers
from config import settings

router = Router()
logger = logging.getLogger(__name__)

DB_PATH = settings.IP_HISTORY_DB
MAP_HTML_PATH = settings.MAP_HTML_PATH

def _sync_build_map_data():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("SELECT DISTINCT ip FROM ip_log;")
    rows = cursor.fetchall()
    conn.close()
    
    all_ips = [row[0] for row in rows if row[0]]
    if not all_ips: return []
    
    coords = []
    rcity, rasn = get_geoip_readers()
    
    for ip in all_ips:
        try:
            if rcity:
                city_rec = rcity.city(ip)
                lat = city_rec.location.latitude
                lon = city_rec.location.longitude
                
                if lat and lon:
                    c_code = city_rec.country.iso_code or "??"
                    flag = country_flag(c_code) if c_code != "??" else "🏳️"
                    city_name = city_rec.city.names.get('ru') or city_rec.city.name or "Unknown"
                    
                    asn_org = "Unknown ISP"
                    if rasn:
                        try:
                            asn_rec = rasn.asn(ip)
                            asn_org = asn_rec.autonomous_system_organization or f"AS{asn_rec.autonomous_system_number}"
                        except Exception: pass
                    
                    popup_text = f"IP: {ip}<br>Гео: {flag} {city_name}<br>Провайдер: {asn_org}"
                    coords.append((lat, lon, popup_text))
        except Exception: continue
    return coords

@router.message(Command("map"))
async def cmd_map(message: types.Message):
    await send_long_message(message, "🗺 Обновляю гео-данные и строю карту...")
    try:
        coords = await asyncio.to_thread(_sync_build_map_data)
        
        if not coords:
            await send_long_message(message, "⚠️ Нет данных по IP в базе или не удалось определить координаты.")
            return
        
        avg_lat = sum(c[0] for c in coords) / len(coords)
        avg_lon = sum(c[1] for c in coords) / len(coords)
        
        m = folium.Map(location=[avg_lat, avg_lon], zoom_start=3, tiles='cartodbpositron')
        cluster = MarkerCluster().add_to(m)
        
        for lat, lon, popup in coords:
            folium.Marker(location=[lat, lon], popup=folium.Popup(popup, max_width=300)).add_to(cluster)
        
        os.makedirs(os.path.dirname(MAP_HTML_PATH), exist_ok=True)
        await asyncio.to_thread(m.save, MAP_HTML_PATH)
        
        # ДОБАВЛЯЕМ ВРЕМЕННУЮ МЕТКУ v=... чтобы избежать кэша в Telegram
        base_url = settings.WEB_URL.rstrip("/")
        web_app_url = f"{base_url}/telemt-map?v={int(time.time())}"
        
        keyboard = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🗺 Открыть карту подключений", web_app=WebAppInfo(url=web_app_url))]
        ])
        
        logger.info(f"Карта сгенерирована: {len(coords)} точек.")
        await message.reply(
            text=f"📊 Карта успешно сгенерирована!\n📍 Всего отмечено точек: {len(coords)}.",
            reply_markup=keyboard,
            parse_mode=ParseMode.HTML
        )
    except Exception as e:
        logger.error(f"Ошибка в cmd_map: {e}")
        await send_long_message(message, f"❌ Ошибка генерации: <code>{e}</code>")
