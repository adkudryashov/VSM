"""
Сводка за сутки по запросу и выключатель ежедневной рассылки.

По запросу — от последнего закрытия суток (22:00 по Москве) до сейчас: те же
числа, что придут вечером, только окно ещё не закрыто. Ничего не сохраняет —
сутки закрывает только расписание, иначе нажатие кнопки днём сдвигало бы
границу и вечерняя сводка показала бы полдня.
"""

import logging
import time

from aiogram import Bot, F, Router, types
from aiogram.filters import Command, StateFilter

from common import keyboards as kb
from telemt.digest import loop
from telemt.digest.ledger import shared as ledger

router = Router(name="digest")


@router.message(StateFilter(None), Command("digest"))
@router.message(StateFilter(None), F.text == kb.BTN_DIGEST)
async def show_digest(message: types.Message, bot: Bot):
    try:
        await bot.send_chat_action(message.chat.id, "typing")
    except Exception:
        pass
    if not ledger().data.get("last_run"):
        await message.answer("📊 Сводка ещё не начала считать: первый снимок делается "
                             "через минуту после запуска бота. Попробуйте чуть позже.")
        return
    try:
        text, _, _ = await loop.build(time.time())
    except Exception as exc:
        logging.warning("Сводка по запросу не собралась: %s", exc)
        await message.answer("⚠️ Сводка не собралась. Подробности в журнале бота.")
        return
    await message.answer(text, parse_mode="HTML", reply_markup=loop.keyboard(ledger().enabled))


@router.callback_query(F.data.in_({"dg:on", "dg:off"}))
async def toggle(callback: types.CallbackQuery):
    on = callback.data == "dg:on"
    ledger().set_enabled(on)
    try:
        await callback.message.edit_reply_markup(reply_markup=loop.keyboard(on))
    except Exception:
        pass  # Сообщение старое или кнопки те же — решение уже сохранено.
    from config import settings
    zone = " по Москве" if settings.DIGEST_TZ == "Europe/Moscow" else f" ({settings.DIGEST_TZ})"
    await callback.answer(
        f"Сводка будет приходить каждый день в {settings.DIGEST_TIME}{zone}."
        if on else f"Ежедневная сводка выключена. Кнопка «{kb.BTN_DIGEST}» по-прежнему работает.",
        show_alert=True)
