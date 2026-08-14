"""
Ограничение доступа к боту: проверка на всех видах событий, а не только там,
где сегодня есть обработчики.

ЗАЧЕМ ОТДЕЛЬНЫЙ ПРОГОН. AuthMiddleware долго висела на dp.message и
dp.callback_query. Обхода это не давало — все обработчики бота ровно двух этих
видов, — но наблюдателей у диспетчера четырнадцать, и один добавленный
@router.inline_query открыл бы бота посторонним молча: проверка просто не
вызвалась бы. Ошибка такого рода не видна ни в обзоре кода, ни в работе.

Поэтому здесь проверяется не «текущие обработчики закрыты», а «закрыт вид
событий, обработчика для которого в боте НЕТ»: inline_query. Если защиту снова
повесят на перечисление видов, этот прогон это поймает.

Каждая проверка парная: свой проходит, чужой не проходит. Проверка, умеющая
только запрещать, доказывает лишь то, что бот сломан.
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bots"))

from aiogram import Bot, Dispatcher, Router
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import Chat, InlineQuery, Message, Update, User

import config
from common.auth import AuthMiddleware

ADMIN = 111
STRANGER = 999

# Токен синтаксически правильный, но заведомо нерабочий: Bot проверяет форму
# при создании, а в сеть этот прогон не ходит вовсе.
FAKE_TOKEN = "111:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

ok = fail = 0


def check(name, got, want):
    global ok, fail
    if got == want:
        ok += 1
        print(f"  ok   {name}")
    else:
        fail += 1
        print(f"  ПРОВАЛ {name}: получено {got!r}, ожидалось {want!r}")


config.settings.ADMIN_IDS = [ADMIN]

reached = []
router = Router()


@router.message()
async def on_message(message: Message):
    reached.append("message")


@router.inline_query()
async def on_inline(query: InlineQuery):
    """Обработчика такого вида в боте нет — он здесь ровно для проверки."""
    reached.append("inline_query")


def _user(uid: int) -> User:
    return User(id=uid, is_bot=False, first_name="проверка")


def _message_update(uid: int) -> Update:
    return Update(update_id=1, message=Message(
        message_id=1, date=0, chat=Chat(id=uid, type="private"),
        from_user=_user(uid), text="/watch"))


def _inline_update(uid: int) -> Update:
    return Update(update_id=2, inline_query=InlineQuery(
        id="1", from_user=_user(uid), query="", offset=""))


async def main() -> None:
    dispatcher = Dispatcher(storage=MemoryStorage())
    dispatcher.update.outer_middleware(AuthMiddleware())
    dispatcher.include_router(router)
    bot = Bot(token=FAKE_TOKEN)

    async def reaches(update: Update) -> bool:
        reached.clear()
        await dispatcher.feed_update(bot, update)
        return bool(reached)

    print("== Обычные сообщения ==")
    check("админ проходит", await reaches(_message_update(ADMIN)), True)
    check("посторонний не проходит", await reaches(_message_update(STRANGER)), False)

    print("== Вид события, обработчика для которого в боте нет ==")
    check("админ проходит", await reaches(_inline_update(ADMIN)), True)
    check("посторонний не проходит", await reaches(_inline_update(STRANGER)), False)

    print("== Пустой список админов не открывает бота всем ==")
    config.settings.ADMIN_IDS = []
    check("админ тоже не проходит", await reaches(_message_update(ADMIN)), False)
    config.settings.ADMIN_IDS = [ADMIN]

    await bot.session.close()


asyncio.run(main())

print()
if fail:
    print(f"ПРОВАЛОВ: {fail}, успешных: {ok}")
    sys.exit(1)
print(f"Все проверки пройдены: {ok}")
