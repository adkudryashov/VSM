"""
Сборка telemt-части: роутеры, список команд и фоновый сбор IP.

Вынесено из точки входа, чтобы то же самое можно было включить
и в объединённого бота без дублирования кода.
"""

import asyncio
import logging

from aiogram.types import BotCommand

from config import settings
from telemt.api.client import TelemtAPIClient
from common import http
from telemt.handlers import (common, users, stats, reports, panel, metrics, map,
                             aboutall, watch, cleanup)
from telemt.utils.storage import init_db, bulk_save_ips, cleanup_old_ips
from telemt.watchdog.monitor import watchdog_loop  # noqa: F401  (реэкспорт для точек входа)

# Порядок важен: aiogram отдаёт событие первому подошедшему обработчику.
ROUTERS = [
    common.router,
    users.router,
    stats.router,
    reports.router,
    panel.router,
    metrics.router,
    map.router,
    aboutall.router,
    watch.router,
    cleanup.router,
]

COMMANDS = [
    BotCommand(command="status",       description="📊 общая статистика"),
    BotCommand(command="user_report",  description="📋 лог подключений IP"),
    BotCommand(command="panel",        description="🎛 панель управления"),
    BotCommand(command="metrics",      description="📈 состояние сервисов"),
    BotCommand(command="usersstatus",  description="👥 все активные сессии"),
    BotCommand(command="map",          description="🗺 карта подключений"),
    BotCommand(command="health",       description="🏥 здоровье API"),
    BotCommand(command="runtime",      description="⚙️ статус инициализации"),
    BotCommand(command="dcs",          description="🌍 состояние датацентров"),
    BotCommand(command="writers",      description="✍️ состояние ME-писателей"),
    BotCommand(command="aboutall",     description="📋 краткая сводка по всем статусам"),
    BotCommand(command="watch",        description="🛡 сторож: инциденты и доступность"),
    BotCommand(command="check",        description="🇷🇺 проверить доступность из РФ"),
    BotCommand(command="mute",         description="🔕 заглушить тревоги"),
    BotCommand(command="unmute",       description="🔔 вернуть тревоги"),
]


async def collect_ips_periodically(bot=None):
    """Фоновый сбор IP. Не зависит от команд и работает всё время."""
    api = TelemtAPIClient()
    cleanup_counter = 0
    # Раз в ~час, а не на каждой итерации — чтобы не гонять DELETE по всей таблице лишний раз
    cleanup_every_n_ticks = max(1, 60 // max(settings.COLLECT_INTERVAL_MINUTES, 1))
    # 0 отключает очистку — история IP копится бессрочно
    cleanup_enabled = settings.ACTIVITY_RETENTION_HOURS > 0
    if not cleanup_enabled:
        logging.info("Очистка ip_log отключена: история IP хранится бессрочно.")

    while True:
        try:
            users_list = await api.users()
            ips_to_save = []
            for user in users_list:
                for ip in user.get('active_unique_ips_list', []):
                    ips_to_save.append((user['username'], ip))

            if ips_to_save:
                await bulk_save_ips(ips_to_save)

            if cleanup_enabled:
                cleanup_counter += 1
                if cleanup_counter >= cleanup_every_n_ticks:
                    cleanup_counter = 0
                    removed = await cleanup_old_ips(settings.ACTIVITY_RETENTION_HOURS)
                    if removed:
                        logging.info(
                            f"Очистка ip_log: удалено {removed} записей старше "
                            f"{settings.ACTIVITY_RETENTION_HOURS} ч."
                        )
        except Exception as e:
            logging.error(f"Ошибка сбора IP: {e}")
        await asyncio.sleep(settings.COLLECT_INTERVAL_MINUTES * 60)


async def setup():
    """Подготовка хранилища перед стартом."""
    await init_db()


async def shutdown(*_args, **_kwargs):
    await TelemtAPIClient().close()
    # Общая сессия aiohttp живёт весь процесс — закрываем её здесь, а не
    # в местах вызова: там она нарочно не закрывается, иначе вернулась бы
    # та самая утечка, ради которой её и завели (см. common/http.py).
    await http.close()
