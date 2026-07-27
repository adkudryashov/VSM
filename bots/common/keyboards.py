"""
Клавиатуры. Telegram показывает ровно одну reply-клавиатуру на чат, поэтому
у объединённого бота она двухуровневая: корень выбирает раздел, раздел
показывает кнопки соответствующего бота плюс «Назад».

Подписи кнопок разделов совпадают с подписями в отдельных ботах, так что
обработчики работают в обоих режимах без изменений.
"""

from aiogram.types import KeyboardButton, ReplyKeyboardMarkup
from aiogram.utils.keyboard import ReplyKeyboardBuilder

# --- Подписи ---
BTN_TELEMT_SECTION = "✈️ Telemt"
BTN_XUI_SECTION = "🎛 3x-ui"
BTN_SUMMARY = "ℹ️ Сводка"
BTN_BACK = "⬅️ Назад"
BTN_CANCEL = "❌ Отмена"

TELEMT_BUTTONS = ["📊 Статус", "⚙️ Метрики", "👥 Активные IP", "📋 Лог IP", "🗺 Карта"]
XUI_BUTTONS = ["📊 Общий статус", "➕ Добавить панель", "🗑️ Удалить панель"]
PANEL_PREFIX = "📱 "

# Всё, что бот считает нажатием кнопки. Нужно, чтобы во время пошагового
# диалога отличить нажатие кнопки от ввода данных: иначе «📊 Статус»,
# нажатое посреди добавления панели, стало бы её именем.
MENU_BUTTONS = set(
    TELEMT_BUTTONS + XUI_BUTTONS
    + [BTN_TELEMT_SECTION, BTN_XUI_SECTION, BTN_SUMMARY, BTN_BACK]
)


def is_menu_button(text: str | None) -> bool:
    if not text:
        return False
    return text in MENU_BUTTONS or text.startswith(PANEL_PREFIX)


def root_keyboard() -> ReplyKeyboardMarkup:
    """Корень объединённого бота: выбор раздела."""
    b = ReplyKeyboardBuilder()
    b.add(KeyboardButton(text=BTN_TELEMT_SECTION))
    b.add(KeyboardButton(text=BTN_XUI_SECTION))
    b.add(KeyboardButton(text=BTN_SUMMARY))
    b.adjust(2, 1)
    return b.as_markup(resize_keyboard=True, one_time_keyboard=False)


def telemt_keyboard(with_back: bool = True) -> ReplyKeyboardMarkup:
    """Раздел Telemt. Без «Назад» — это клавиатура отдельного telemt-бота."""
    b = ReplyKeyboardBuilder()
    for text in TELEMT_BUTTONS:
        b.add(KeyboardButton(text=text))
    if with_back:
        b.add(KeyboardButton(text=BTN_BACK))
        b.adjust(2, 2, 1, 1)
    else:
        b.adjust(2, 2, 1)
    return b.as_markup(resize_keyboard=True, one_time_keyboard=False)


def xui_keyboard(panel_names, with_back: bool = True) -> ReplyKeyboardMarkup:
    """Раздел 3x-ui. Список панелей меняется, поэтому строится каждый раз."""
    names = list(panel_names)
    b = ReplyKeyboardBuilder()
    b.add(KeyboardButton(text="📊 Общий статус"))
    for name in names:
        b.add(KeyboardButton(text=f"{PANEL_PREFIX}{name}"))
    b.add(KeyboardButton(text="➕ Добавить панель"))
    b.add(KeyboardButton(text="🗑️ Удалить панель"))

    rows = [1, len(names), 2] if names else [1, 2]
    if with_back:
        b.add(KeyboardButton(text=BTN_BACK))
        rows.append(1)
    b.adjust(*rows)
    return b.as_markup(resize_keyboard=True, one_time_keyboard=False)


def cancel_keyboard() -> ReplyKeyboardMarkup:
    """Показывается на время пошагового диалога — единственный выход из него."""
    b = ReplyKeyboardBuilder()
    b.add(KeyboardButton(text=BTN_CANCEL))
    return b.as_markup(resize_keyboard=True, one_time_keyboard=False)
