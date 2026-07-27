from aiogram.types import ReplyKeyboardMarkup

from common import keyboards as kb


def get_main_keyboard() -> ReplyKeyboardMarkup:
    """
    Постоянная клавиатура отдельного telemt-бота: без кнопки «Назад»,
    подниматься некуда — разделов нет.

    Подписи кнопок общие с разделом Telemt объединённого бота, поэтому
    обработчики в handlers/panel.py обслуживают оба случая без изменений.
    """
    return kb.telemt_keyboard(with_back=False)
