from telemt.utils.helpers import send_long_message
import asyncio
import html
import os
import time
import logging
from aiogram import Router, types
from aiogram.filters import Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton, WebAppInfo
from aiogram.enums import ParseMode
import sqlite3
from telemt.utils import mapassets
from telemt.utils.geo import country_flag, get_geoip_readers
from config import settings

router = Router()
logger = logging.getLogger(__name__)


def _load_folium():
    """Подключить folium в момент использования, а не при старте бота.

    ПОЧЕМУ НЕ ОБЫЧНЫЙ import СВЕРХУ. folium тянет за собой numpy, а numpy,
    начиная с версии 2, собирается с базовым уровнем x86-64-v2 и при импорте
    падает RuntimeError на процессорах без SSE4.2, SSSE3 и POPCNT. Такие
    процессоры — обычное дело у хостеров с эмуляцией: на приёмке 27.08.2026
    попался «QEMU Virtual CPU version 2.5+», где из пяти признаков v2 есть
    ровно один.

    Импорт стоял на верхнем уровне модуля, модуль подключался из panel.py, и
    падение numpy убивало ВЕСЬ бот при старте. Вместе с ним — сторожа, то есть
    единственный источник тревог о падении прокси. Необязательная карта делала
    непригодным всё остальное.

    Теперь не запускается только карта, и она объясняет причину.
    """
    try:
        import folium
        from folium.plugins import MarkerCluster
        return folium, MarkerCluster
    except Exception as exc:
        logger.warning("folium недоступен, карта отключена: %s", exc)
        return None, None

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
                    
                    # Экранируем: имя города и название провайдера приходят из
                    # базы MaxMind, то есть из чужого файла, а попадают прямо в
                    # разметку страницы. Кавычка в названии оператора рвала бы
                    # всплывающую подпись, а угловая скобка — и всю карту.
                    popup_text = (f"IP: {html.escape(str(ip))}<br>"
                                  f"Гео: {flag} {html.escape(str(city_name))}<br>"
                                  f"Провайдер: {html.escape(str(asn_org))}")
                    coords.append((lat, lon, popup_text))
        except Exception: continue
    return coords

@router.message(Command("map"))
async def cmd_map(message: types.Message):
    folium, MarkerCluster = _load_folium()
    if folium is None:
        await send_long_message(
            message,
            "🗺 Карта недоступна: библиотека folium не загрузилась.\n\n"
            "Чаще всего причина — процессор без SSE4.2 и POPCNT: numpy 2.4 и "
            "новее на таких машинах не запускается. Всё остальное работает.\n\n"
            "Починка: <code>bots/venv/bin/pip install \"numpy&lt;2.4\"</code>\n"
            "и перезапуск бота.",
        )
        return

    await send_long_message(message, "🗺 Обновляю гео-данные и строю карту...")
    try:
        coords = await asyncio.to_thread(_sync_build_map_data)
        
        if not coords:
            await send_long_message(message, "⚠️ Нет данных по IP в базе или не удалось определить координаты.")
            return
        
        avg_lat = sum(c[0] for c in coords) / len(coords)
        avg_lon = sum(c[1] for c in coords) / len(coords)
        
        # ПОДЛОЖКА — OpenStreetMap, а не CartoDB.
        #
        # cartodbpositron тянул плитки с basemaps.cartocdn.com, и CartoDB
        # закрыл их бесплатную отдачу: карта строилась, но поверх всей
        # площади шли водяные знаки «API KEY REQUIRED». Увидено на приёмке
        # 27.08.2026 — по коду это не отличить от исправной карты, отдаётся
        # тот же HTTP 200 с картинкой.
        #
        # На приватность замена не влияет: сервер плиток в обоих случаях видит
        # адрес смотрящего и разглядываемые районы, но не секретный путь —
        # его прячет Referrer-Policy: no-referrer. Это тот же размен, который
        # владелец принял при разборе карты 14.08.2026, только провайдер
        # другой и без ключа.
        m = folium.Map(location=[avg_lat, avg_lon], zoom_start=3, tiles='OpenStreetMap')
        cluster = MarkerCluster().add_to(m)
        
        for lat, lon, popup in coords:
            folium.Marker(location=[lat, lon], popup=folium.Popup(popup, max_width=300)).add_to(cluster)
        
        map_dir = os.path.dirname(MAP_HTML_PATH)
        os.makedirs(map_dir, exist_ok=True)

        # Страницу собираем в память и правим ДО записи на диск: библиотеки
        # заменяются локальными копиями, лишние чужие скрипты вырезаются.
        # Подробности и цена вопроса — в utils/mapassets.py.
        def _render_local() -> int:
            page = m.get_root().render()
            page, left = mapassets.localize(page, map_dir)
            with open(MAP_HTML_PATH, "w", encoding="utf-8") as fh:
                fh.write(page)
            return left

        remote_left = await asyncio.to_thread(_render_local)
        if remote_left:
            logger.warning("Карта: наружу по-прежнему смотрят %s ссылок", remote_left)

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
        # Экранируем текст исключения: без этого любая угловая скобка в нём
        # делала сообщение неразбираемым для Telegram, тот отвечал отказом, и
        # владелец не получал НИЧЕГО — ни карты, ни объяснения, почему её нет.
        await send_long_message(message, f"❌ Ошибка генерации: <code>{html.escape(str(e))}</code>")
