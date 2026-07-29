"""
Общий выбор даты: пресеты, инлайн-календарь и ручной ввод.

Живёт в common/, потому что не знает ни о панелях, ни о базе — отдаёт date и
только. Календарь собран на stdlib calendar: тянуть внешнюю библиотеку ради
одного экрана незачем.

Наружу дата всегда ДД-ММ-ГГГГ, внутрь базы — ISO. Конвертация собрана здесь,
чтобы читатели expiry_date (фоновые алерты, таблица статуса) не менялись.
"""

import calendar
from datetime import date, datetime

from aiogram.filters.callback_data import CallbackData
from aiogram.types import InlineKeyboardMarkup
from aiogram.utils.keyboard import InlineKeyboardBuilder

DISPLAY_FORMAT = "%d-%m-%Y"
ISO_FORMAT = "%Y-%m-%d"

MANUAL_PROMPT = "Введите дату в формате ДД-ММ-ГГГГ (например, 31-12-2026):"
MANUAL_ERROR = "❌ Не разобрал дату. Нужен формат ДД-ММ-ГГГГ, например 31-12-2026:"
STALE_ANSWER = "⌛ Это меню устарело — начните заново."

# Границы навигации: подписка на VPS дальше этих лет не заводится, а без
# ограничения кнопки-стрелки уводят календарь в произвольный год.
MIN_YEAR = 2020
MAX_YEAR = 2100

_MONTHS = ("Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
           "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь")
_WEEKDAYS = ("Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс")
_PRESETS = (("+1 месяц", "1m"), ("+3 месяца", "3m"), ("+1 год", "1y"))
_PRESET_MONTHS = {"1m": 1, "3m": 3, "1y": 12}


class DateCb(CallbackData, prefix="dp"):
    """
    Одна фабрика на все кнопки виджета.

    Имени панели здесь намеренно нет: в callback_data всего 64 байта, имя
    задаёт админ, оно бывает кириллическим (два байта на символ) и живёт
    ровно столько же кликов, сколько открыт календарь. Панель хранится в FSM,
    в кнопках — только координаты даты.
    """
    action: str        # presets | calendar | nav | day | manual | preset | cancel | noop
    year: int = 0
    month: int = 0
    day: int = 0
    value: str = ""    # ключ пресета для action="preset"


def shift(base: date, key: str) -> date:
    """Пресеты. 31 января + 1 месяц = 28 февраля, а не исключение."""
    total = base.month - 1 + _PRESET_MONTHS[key]
    year = base.year + total // 12
    month = total % 12 + 1
    return date(year, month, min(base.day, calendar.monthrange(year, month)[1]))


def parse_manual(text: str) -> date | None:
    try:
        return datetime.strptime(text.strip(), DISPLAY_FORMAT).date()
    except (ValueError, AttributeError):
        return None


def to_display(value) -> str:
    """Принимает date или ISO-строку из базы — вызывающему не нужно знать, что пришло."""
    if isinstance(value, str):
        try:
            value = datetime.strptime(value, ISO_FORMAT).date()
        except ValueError:
            return "—"
    if not isinstance(value, date):
        return "—"
    return value.strftime(DISPLAY_FORMAT)


def to_iso(value: date) -> str:
    return value.strftime(ISO_FORMAT)


def presets_keyboard(base: date) -> InlineKeyboardMarkup:
    """Первый экран: типовые сроки закрывают почти все случаи одним нажатием."""
    b = InlineKeyboardBuilder()
    for label, key in _PRESETS:
        b.button(text=label, callback_data=DateCb(action="preset", value=key))
    b.button(text="📅 Календарь",
             callback_data=DateCb(action="calendar", year=base.year, month=base.month))
    b.button(text="✏️ Ввести вручную", callback_data=DateCb(action="manual"))
    b.button(text="🚫 Отмена", callback_data=DateCb(action="cancel"))
    b.adjust(3, 2, 1)
    return b.as_markup()


def calendar_keyboard(year: int, month: int) -> InlineKeyboardMarkup:
    """
    Сетка месяца. Прошедшие даты не блокируются: подписку заводят и задним
    числом, а перекрытая навигация не даст исправить опечатку в прошлое.
    Просроченный срок и так виден 🔴 в таблице статуса.
    """
    year = min(max(year, MIN_YEAR), MAX_YEAR)
    b = InlineKeyboardBuilder()

    prev_y, prev_m = (year - 1, 12) if month == 1 else (year, month - 1)
    next_y, next_m = (year + 1, 1) if month == 12 else (year, month + 1)
    b.button(text="◀️", callback_data=DateCb(action="nav", year=prev_y, month=prev_m))
    b.button(text=f"{_MONTHS[month - 1]} {year}", callback_data=DateCb(action="noop"))
    b.button(text="▶️", callback_data=DateCb(action="nav", year=next_y, month=next_m))
    for weekday in _WEEKDAYS:
        b.button(text=weekday, callback_data=DateCb(action="noop"))
    rows = [3, 7]

    for week in calendar.Calendar(firstweekday=0).monthdayscalendar(year, month):
        for day in week:
            if day:
                b.button(text=str(day),
                         callback_data=DateCb(action="day", year=year, month=month, day=day))
            else:
                # Пустую подпись Telegram не принимает, а голое "noop" в
                # callback_data перехватил бы обработчик telemt-части: его
                # роутеры подключаются раньше. Отсюда своя фабрика и точка.
                b.button(text="·", callback_data=DateCb(action="noop"))
        rows.append(7)

    b.button(text="↩️ К пресетам", callback_data=DateCb(action="presets"))
    b.button(text="🚫 Отмена", callback_data=DateCb(action="cancel"))
    rows += [1, 1]

    b.adjust(*rows)
    return b.as_markup()
