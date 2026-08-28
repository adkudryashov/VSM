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
from telemt.watchdog import mtproxyl
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

    СТОИТ У СТРОКИ «СБОИ», А НЕ «УСПЕШНЫХ». Оценка считается по доле успеха, но
    показывать её надо там, где смысл совпадает с цветом: «🔴 Успешных 72.8%»
    читается как «успешные — это плохо», и глаз спотыкается каждый раз.
    Красный у сбоев означает ровно то, что видно: сбоев многовато. Замечено
    владельцем на первой живой сводке 27.08.2026.
    """
    if success_percent >= 99:
        return OK
    if success_percent >= 95:
        return WARN
    return BAD




# Классы отказов, которые НЕ говорят о работе прокси.
#
# Сюда telemt относит всех, кто постучался в порт и не оказался клиентом
# MTProto: сканер, браузер, наш собственный зонд доступности, чужой софт,
# перепутавший порт. Разобрать их между собой счётчик не позволяет — см.
# _stray_line.
_STRAY_CLASSES = {"tls_handshake_bad_client"}

# Порог «необычно много» для соединений, не ставших клиентами, в час.
#
# Взят из единственного пока замера (стенд, 28.08.2026): в спокойные часы этот
# счётчик прибавляет от 15 до 100 в час — фон интернета плюс наши же зонды. С
# 09:00 до 13:58:59 того дня он рос по 2700 в час пять часов подряд и оборвался
# так же резко, как начался. Порог 300 отстоит от обоих значений на порядок:
# колебания фона его не задевают, а событие такого размера видно сразу.
#
# Это НЕ тревога и никого не будит — строка лишь перестаёт молчать.
STRAY_RATE_HIGH = 300.0


def _stray_line(total: int, uptime_seconds: float, own_per_hour: float = 0.0) -> str:
    """
    Строка про соединения, которые не стали клиентами. Пустая, если их нет.

    ЧТО ЭТО ЗА СЧЁТЧИК. Всё, что не прошло маскировку: маскировка отдала гостя
    на запасную страницу, сессии не возникло. Мы никому ничего не сломали —
    наоборот, защита отработала.

    ПОЧЕМУ ЗДЕСЬ НЕТ СЛОВА «СКАНЕРЫ». Прежде строка называла их сканерами, и
    это было домыслом, а не измерением. Разбор 28.08.2026 по журналам nginx на
    стенде: из 13 754 таких соединений за 11 часов до HTTP-запроса дошли 710,
    и только 100 из них имели узнаваемую подпись сканера (zgrab, l9scan,
    CensysInspect, GenomeCrawler); 440 оказались НАШИМИ зондами доступности, а
    остальные 12 740 не осилили TLS даже с запасной страницей — слали вообще
    не TLS, и адрес их нигде не записан. То есть 93% цифры не подтверждено
    ничем, а часть её мы создаём сами.

    Контрольный случай на том же стенде: обычный `openssl s_client` и восемь
    байт мусора через `nc` подняли счётчик на два. В этот класс попадает ЛЮБОЙ
    не подошедший гость — включая клиента владельца с устаревшей ссылкой.
    Поэтому назвать их чужими нельзя, а показать — нужно.

    ПОЧЕМУ ОНИ ВНЕ ОЦЕНКИ ЗДОРОВЬЯ. Счётчик накопительный от старта, и его доля
    растёт ровно по мере того, как сервер дольше стоит в интернете: 27.08.2026
    сводка на этом основании красила исправный сервер красным. Оценка, которая
    со временем обязана испортиться у всех, ничего не оценивает.

    ПОЧЕМУ РЯДОМ СКОРОСТЬ. Вычитать класс молча опасно: если однажды сменится
    секрет, отказы всех клиентов лягут ровно сюда, и сводка покажет «успешных
    100%» при полностью неработающем прокси. Скорость в час — то немногое, что
    отличает спокойный фон от события, и она остаётся на виду.

    ОГОВОРКА: скорость средняя от старта службы, поэтому она запаздывает —
    закончившийся всплеск держит её высокой ещё несколько часов. Для «сказать»
    этого хватает, для тревоги — нет, и тревоги здесь нет.
    """
    if total <= 0:
        return ""

    hours = uptime_seconds / 3600.0 if uptime_seconds > 0 else 0.0
    rate = total / hours if hours > 0 else 0.0
    high = rate >= STRAY_RATE_HIGH

    line = f"{WARN if high else '🔍'} Не стали клиентами: {format_connections(total)}"
    if hours > 0:
        line += f" · {format_connections(int(round(rate)))}/час"

    # Наши зонды показываем отдельно, а не вычитаем из общего числа: их
    # количество СЧИТАНО из настроек, а не измерено, и подмешивать расчётное к
    # измеренному в одну цифру значит потерять разницу между ними навсегда.
    own_total = min(own_per_hour * hours, float(total)) if own_per_hour > 0 else 0.0
    if own_total >= 1:
        line += f" (наши зонды ≈{format_connections(int(round(own_total)))})"

    return line + (" — необычно много, в оценку не входят" if high
                   else " — в оценку не входят")

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

    # Соединения, не ставшие клиентами, — отдельно от оценки здоровья.
    # Разбор счётчика, порог и почему в строке больше нет слова «сканеры» —
    # в _stray_line выше.
    _by_class = summary_data.get('connections_bad_by_class') or []
    stray_bad = sum(
        int(c.get('total', 0)) for c in _by_class
        if c.get('class') in _STRAY_CLASSES
    )
    real_bad = max(0, connections_bad - stray_bad)
    real_total = max(0, connections_total - stray_bad)
    real_bad_percent = (real_bad / real_total * 100) if real_total > 0 else 0
    real_success_percent = 100 - real_bad_percent if real_total > 0 else 100
    # Доля успешных считается от ТОГО ЖЕ знаменателя, что и доля сбоев.
    # Иначе рядом стоят «Сбои 0 (0%)» и «Успешных 78.7%», и верят той строке,
    # которая пугает: если сбоев ноль, успешных обязано быть сто. Замечено
    # сразу после первой правки — половину дроби починил, половину нет.
    current_version = sys_data.get('version', 'неизвестно')
    version_text = _version_line(current_version, latest_version)
    mark = _quality_mark(real_success_percent)
    # Строку готовим заранее: подставить условие прямо в цепочку f-строк
    # нельзя — после «+» соседние литералы уже не склеиваются.
    stray_text = _stray_line(stray_bad, summary_data['uptime_seconds'],
                             mtproxyl.own_probes_per_hour())

    text = (
        f"🔹 Статус:\n"
        f"• Аптайм: {format_uptime(summary_data['uptime_seconds'])}\n"
        f"• Трафик: {format_traffic(total_traffic)}\n"
        f"• Версия: {version_text}\n\n"
        f"🔹 Сетевая активность:\n"
        f"🌐 Активных IP: {total_active_ips}\n"
        f"🌐 Всего соединений: {format_connections(connections_total)}\n"
        f"┗━ Успешных: {format_connections(good_connections)} ({format_percent(real_success_percent)})\n"
        f"┗━ {mark} Сбои: {format_connections(real_bad)} ({format_percent(real_bad_percent)})"
        + (f"\n┗━ {stray_text}" if stray_text else "")
    )
    stray_row = (
        f"<tr><td colspan=\"4\">{html.escape(stray_text)}</td></tr>"
    ) if stray_text else ""

    # Один экран в две колонки вместо двух таблиц одна под другой.
    # colspan в HTML-режиме проверен ответом sendRichMessage: сервер
    # возвращает заголовки как две ячейки с colspan=2.
    rich_html = (
        f"<table>"
        f"<tr><th colspan=\"2\">Статус</th><th colspan=\"2\">Сетевая активность</th></tr>"
        f"<tr><td>Аптайм</td><td>{html.escape(format_uptime(summary_data['uptime_seconds']))}</td>"
        f"<td>Всего соединений</td><td>{html.escape(format_connections(connections_total))}</td></tr>"
        f"<tr><td>Трафик</td><td>{html.escape(format_traffic(total_traffic))}</td>"
        f"<td>Успешных</td><td>{html.escape(format_connections(good_connections))} ({format_percent(real_success_percent)})</td></tr>"
        f"<tr><td>Активные IP</td><td>{total_active_ips}</td>"
        f"<td>{mark} Сбои</td><td>{html.escape(format_connections(real_bad))} ({format_percent(real_bad_percent)})</td></tr>"
        f"{stray_row}"
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
