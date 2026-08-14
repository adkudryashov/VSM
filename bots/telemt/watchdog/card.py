"""
Живая карточка сторожа: одно сообщение на чат, которое правится на месте.

ЗАЧЕМ. Лента отдельных сообщений о состоянии засоряет чат и при этом плохо
отвечает на единственный вопрос, который к ней есть: «как сейчас». Ответ на
него всегда один, и держать его стоит в одном сообщении, а не в двадцатом
сверху. Карточка правится молча, без звука и без переноса вниз.

ГЛАВНОЕ ПРАВИЛО, КОТОРОЕ НЕЛЬЗЯ НАРУШАТЬ: тревоги остаются ОТДЕЛЬНЫМИ
сообщениями и шлются мимо карточки. Свернуть аварию в тихую правку — значит
проспать ночное падение: карточка обновится, но смотреть на неё некому.
Карточка отвечает «как сейчас», тревога говорит «проснись». Это разные задачи,
и объединять их нельзя, как бы ни хотелось убрать сообщения из чата.

ПОЧЕМУ В КАРТОЧКЕ НЕТ ОТМЕТКИ ВРЕМЕНИ. С ней текст менялся бы каждую минуту,
и правка уходила бы в Telegram на каждый опрос — вместо одной правки в час,
когда действительно что-то поменялось. Свежесть и так видна: Telegram сам
помечает изменённые сообщения, а возраст последней проверки из РФ напечатан
внутри.
"""

import asyncio
import html
import logging
import time

from aiogram import Bot
from aiogram.exceptions import TelegramBadRequest
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

from config import settings
from telemt.watchdog.monitor import watchdog

# Последний отправленный текст по каждому чату. В памяти: единственная его
# задача — не слать в Telegram правку, которая ничего не меняет. После
# перезапуска бота одна лишняя правка ничего не стоит.
_last_text: dict = {}


def keyboard() -> InlineKeyboardMarkup:
    """
    Кнопки под карточкой. Пауза меняется на снятие, когда тревоги заглушены:
    иначе единственный способ узнать, что бот молчит по вашей же просьбе, —
    прочитать это в тексте, а кнопка продолжала бы предлагать заглушить ещё раз.
    """
    muted = watchdog.state.muted(time.time())
    pause = (InlineKeyboardButton(text="🔔 Снять паузу", callback_data="wd:unmute")
             if muted else
             InlineKeyboardButton(text="🔕 Пауза", callback_data="wd:mute"))
    rows = [[
        InlineKeyboardButton(text="🔄 Обновить", callback_data="wd:refresh"),
        InlineKeyboardButton(text="🇷🇺 Проверить", callback_data="wd:check"),
    ]]
    # «Зонды» показываются, только когда есть что показать: кнопка, которая на
    # половине установок отвечает «данных нет», хуже её отсутствия.
    if (watchdog.ru_last or {}).get("probes"):
        rows.append([InlineKeyboardButton(text="🔍 Зонды", callback_data="wd:probes")])
    rows.append([pause])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def render_probes() -> str:
    """
    Разбор последней проверки по зондам: город, провайдер, дошёл ли.

    Общий процент не отвечает на вопрос «у кого именно не работает», а он и
    есть главный: блокировка почти никогда не бывает поголовной, она начинается
    с одного-двух операторов. Неудачные идут первыми — ради них и смотрят.
    """
    verdict = watchdog.ru_last or {}
    probes = verdict.get("probes") or []
    if not probes:
        return "Разбора по зондам ещё нет — дождитесь следующей проверки."

    lines = [f"🔍 <b>Зонды: дошло {verdict.get('success', 0)} из "
             f"{verdict.get('total', 0)}</b>", ""]
    for probe in sorted(probes, key=lambda p: bool(p.get("ok"))):
        where = probe.get("city") or "—"
        who = probe.get("network") or "оператор не назван"
        asn = probe.get("asn")
        tail = f" (AS{asn})" if asn else ""
        mark = "✅" if probe.get("ok") else "❌"
        line = f"{mark} {html.escape(where)} · {html.escape(who)}{tail}"
        if not probe.get("ok"):
            line += f"\n     <i>{html.escape(str(probe.get('error') or ''))}</i>"
        lines.append(line)
    return "\n".join(lines)


def mute_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="30 минут", callback_data="wd:mute:30"),
        InlineKeyboardButton(text="2 часа", callback_data="wd:mute:120"),
        InlineKeyboardButton(text="До отмены", callback_data="wd:mute:0"),
    ], [
        InlineKeyboardButton(text="◀️ Назад", callback_data="wd:refresh"),
    ]])


async def refresh(bot: Bot, *, relocate: bool = False, force: bool = False) -> None:
    """
    Перерисовывает карточку во всех чатах администраторов.

    relocate — не править на месте, а удалить и отправить заново: карточка
    уехала вверх, и человек попросил её командой. Правка на месте в этом случае
    выглядит как «ничего не произошло».

    force — нарисовать даже если текст не изменился: это поведение кнопки
    «Обновить», человек уже смотрит на сообщение и ждёт отклика.
    """
    text = watchdog.render_status()
    for admin_id in settings.ADMIN_IDS:
        try:
            await _refresh_one(bot, admin_id, text, relocate=relocate, force=force)
        except Exception as exc:
            logging.warning("Карточка сторожа: %s — %s", admin_id, exc)


async def _refresh_one(bot: Bot, admin_id: int, text: str, *,
                       relocate: bool, force: bool) -> None:
    key = str(admin_id)
    message_id = watchdog.state.cards.get(key)

    if message_id and relocate:
        try:
            await bot.delete_message(chat_id=admin_id, message_id=message_id)
        except Exception:
            # Не удалилось — не беда: старая карточка останется замершей выше,
            # а новая уйдёт вниз. Ради этого прерывать перенос незачем.
            pass
        message_id = None

    if message_id:
        if _last_text.get(key) == text and not force:
            return
        try:
            await bot.edit_message_text(text, chat_id=admin_id, message_id=message_id,
                                        parse_mode="HTML", reply_markup=keyboard())
            _last_text[key] = text
            return
        except TelegramBadRequest as exc:
            if "message is not modified" in str(exc):
                # Наш кэш разошёлся с действительностью — выровняем и промолчим.
                _last_text[key] = text
                return
            # Сообщение удалили, или ему больше 48 часов и править его нельзя.
            # Единственный случай, когда карточку заводят заново.
            logging.info("Карточка сторожа %s недоступна для правки (%s) — "
                         "отправляю новую", admin_id, exc)
        except Exception as exc:
            # Сеть или Telegram недоступен. Новую слать НЕЛЬЗЯ: при затяжном
            # сбое бот засыпал бы чат карточками по одной в минуту.
            logging.warning("Карточка сторожа %s не обновлена: %s", admin_id, exc)
            return

    message = await bot.send_message(admin_id, text, parse_mode="HTML",
                                     reply_markup=keyboard())
    watchdog.state.cards[key] = message.message_id
    _last_text[key] = text
    watchdog.save()


async def run_check_and_refresh(bot: Bot) -> None:
    """
    Проверка доступности по кнопке. Идёт десятки секунд, поэтому запускается
    отдельной задачей: Telegram ждёт ответа на нажатие не дольше нескольких
    секунд, и держать его всё это время нельзя.
    """
    try:
        await watchdog.run_ru_check(bot, manual=True)
    except Exception as exc:
        logging.warning("Проверка по кнопке не удалась: %s", exc)
    await refresh(bot, force=True)


def spawn_check(bot: Bot) -> None:
    asyncio.create_task(run_check_and_refresh(bot))
