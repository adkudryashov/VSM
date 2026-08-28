import logging
from datetime import datetime, timezone

from aiogram import types
from aiogram.types import InputRichMessage
from aiogram.exceptions import TelegramBadRequest

def format_traffic(bytes_val: int) -> str:
    """
    Единственное определение на весь telemt: раньше эта функция была скопирована
    в common.py и reports.py, и правка в одной не доезжала до второй.
    Значение приходит из API, поэтому нечисло тоже нужно пережить.
    """
    try:
        val = int(bytes_val)
    except (ValueError, TypeError):
        return "0 KB"
    if val < 1024 * 1024:
        return f"{val / 1024:.1f} KB"
    elif val < 1024 * 1024 * 1024:
        return f"{val / (1024 * 1024):.1f} MB"
    else:
        return f"{val / (1024 * 1024 * 1024):.2f} GB"

def format_percent(value: float) -> str:
    """
    Округление до знака скрывает малое, но ненулевое: 11 сбоев из 30500 —
    это 0.036%, и «0.0%» рядом с одиннадцатью сбоями читается как «сбоев нет»,
    а «100.0%» успешных противоречит соседней строке. Поэтому ровный ноль и
    ровная сотня имеют свои формы, а всё, что не дотягивает до младшего знака,
    показывается границей: «<0.1%» — это честно, «0.0%» — нет.
    """
    if value <= 0:
        return "0%"
    if value >= 100:
        return "100%"
    if value < 0.1:
        return "<0.1%"
    if value > 99.9:
        return ">99.9%"
    return f"{value:.1f}%"

def _local_dt(value):
    """ISO-строка из базы → datetime в местном поясе. Не разобралось — None."""
    try:
        dt = datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None
    # В базе время пишется в UTC, но у старых записей может не быть пояса —
    # тогда считаем UTC, иначе astimezone сдвинет их на местный дважды.
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone()


def format_period(first: str | None, last: str | None) -> str:
    """
    Период по-человечески: «28.08, 09:17 — 10:43».

    В базе лежит ISO с поясом — «2026-08-28T04:17+00:00». Печатать это как есть
    нельзя: строка длинная, время чужое (UTC при сервере в +05), и читать её
    приходится по складам. Замечено владельцем на живом экране очистки.

    Один день — дата пишется один раз. Одна запись — одно время, без тире:
    диапазон из точки в ту же точку выглядит как ошибка.
    """
    a, b = _local_dt(first), _local_dt(last)
    if a is None or b is None:
        return ""
    if a == b:
        return f"{a:%d.%m в %H:%M}"
    if a.date() == b.date():
        return f"{a:%d.%m}, {a:%H:%M} — {b:%H:%M}"
    return f"{a:%d.%m %H:%M} — {b:%d.%m %H:%M}"


def format_uptime(seconds: float) -> str:
    """Аптайм словами: недели-дни-часы-минуты, пустые разряды опускаются."""
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
    """Счётчик соединений с сокращением до k и M; ровные тысячи без дробной части."""
    if value < 1000: return str(value)
    elif value < 1_000_000: return f"{value/1000:.1f}k" if value % 1000 != 0 else f"{value//1000}k"
    else: return f"{value/1_000_000:.1f}M"

# collapse переехал в common/format.py — там его видят обе части бота.
# Здесь оставлен реэкспорт: вызовы вида `from telemt.utils.helpers import
# collapse` продолжают работать, а определение остаётся одно.
from common.format import COLLAPSE_MIN_LINES, collapse  # noqa: F401

# Предупреждение о неудаче Rich Message — ОДИН раз за жизнь процесса.
#
# Прежде оно печаталось при каждом откате, отдельным сообщением, вместе с
# текстом исключения. На сервере, где Rich Messages почему-либо не работают,
# это давало по два сообщения на каждую команду: сначала жалоба с чужой
# английской ошибкой, потом сам ответ. Причина при этом одна и та же, и
# сообщать о ней двадцатый раз — шум, а не забота.
#
# Текст исключения убран из чата намеренно: он приходит от чужого API и может
# нести внутренности, а пользы человеку не несёт — решение всё равно одно.
_rich_warned = False


async def send_rich_or_fallback(message: types.Message, html_content: str, fallback_text: str, reply_markup=None):
    """
    Отправляет Rich Message (Bot API 10.1); при любой ошибке API — откатывается
    на обычный HTML-текст через send_long_message, чтобы бот не падал.
    reply_markup (если передан) прокидывается в обоих случаях — и в Rich
    Message, и в фолбэк — чтобы интерактивные кнопки (например, выбор
    пользователя или пагинация) не терялись независимо от исхода.
    """
    try:
        kwargs = {"reply_markup": reply_markup} if reply_markup is not None else {}
        await message.bot.send_rich_message(
            chat_id=message.chat.id,
            rich_message=InputRichMessage(html=html_content),
            **kwargs
        )
    except Exception as e:
        global _rich_warned
        logging.warning("Rich Message не отправился, показываю обычным текстом: %s", e)
        if not _rich_warned:
            _rich_warned = True
            await message.answer(
                "⚠️ Rich Message недоступен — показываю обычным текстом.\n"
                "Дальше повторять не буду, причина в журнале бота."
            )
        kwargs = {"reply_markup": reply_markup} if reply_markup is not None else {}
        await send_long_message(message, fallback_text, **kwargs)

async def edit_rich_or_fallback(target_message: types.Message, html_content: str, fallback_text: str, reply_markup=None):
    """
    Редактирует существующее сообщение как Rich Message — editMessageText
    поддерживает параметр rich_message начиная с Bot API 10.1 / aiogram 3.29+
    (aiogram.types.Message.edit_text(rich_message=...)). Сообщение
    обновляется на месте, а не отправляется заново — кнопки (пагинация,
    выбор пользователя) продолжают работать под тем же сообщением.

    При ошибке Rich Message откатывается на обычный HTML-текст тем же
    edit_text(). "Message is not modified" (двойной клик на ту же страницу)
    отличается от реальных ошибок Rich Message — в этом случае просто
    молча ничего не делаем, как и раньше.
    """
    try:
        await target_message.edit_text(rich_message=InputRichMessage(html=html_content), reply_markup=reply_markup)
    except TelegramBadRequest as e:
        if "message is not modified" in str(e).lower():
            return
        try:
            await target_message.edit_text(fallback_text, reply_markup=reply_markup, parse_mode="HTML")
        except TelegramBadRequest as e2:
            if "message is not modified" not in str(e2).lower():
                raise
    except Exception:
        await target_message.edit_text(fallback_text, reply_markup=reply_markup, parse_mode="HTML")

async def send_long_message(message: types.Message, text: str, **kwargs):
    kwargs.pop('parse_mode', None)  # Избегаем конфликтов аргументов
    
    if len(text) <= 3900:
        await message.answer(text, parse_mode="HTML", **kwargs)
        return

    # Умное разбиение по строкам, чтобы не ломать HTML-теги внутри строк
    lines = text.split('\n')
    current_chunk = []
    current_length = 0

    for line in lines:
        # Страховка на случай, если одна строка сама по себе огромная
        if len(line) > 3900:
            if current_chunk:
                await message.answer('\n'.join(current_chunk), parse_mode="HTML", **kwargs)
                current_chunk = []
                current_length = 0
            for i in range(0, len(line), 3900):
                await message.answer(line[i:i+3900], parse_mode="HTML", **kwargs)
            continue

        # Если добавление строки превысит лимит Telegram
        if current_length + len(line) + 1 > 3900:
            await message.answer('\n'.join(current_chunk), parse_mode="HTML", **kwargs)
            current_chunk = [line]
            current_length = len(line)
        else:
            current_chunk.append(line)
            current_length += len(line) + 1

    if current_chunk:
        await message.answer('\n'.join(current_chunk), parse_mode="HTML", **kwargs)
