"""
Сводка за сутки: расписание, сборка и отправка.

Раз в минуту цикл делает две вещи: замечает пик подключений (иначе его не
узнать — сервер хранит только «сейчас») и проверяет, не пора ли закрывать
сутки. В DIGEST_TIME по поясу DIGEST_TZ сутки закрываются ВСЕГДА, даже при
выключенной рассылке: иначе кнопка «За сутки» после недели выключенной
рассылки показывала бы неделю, а не сутки.

Бот стоял в момент рассылки (обновление, перезапуск) — сводка уйдёт при старте,
с честной длиной окна в заголовке, а не будет потеряна до следующего вечера.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time

from aiogram import Bot
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup, InputRichMessage

from common import http
from common.beszel import shared as beszel_client
from config import settings
from telemt.api.client import TelemtAPIClient
from telemt.digest import report, sources
from telemt.digest.ledger import shared as ledger

TICK = 60


def keyboard(enabled: bool) -> InlineKeyboardMarkup:
    btn = (InlineKeyboardButton(text="🔕 Не присылать каждый день", callback_data="dg:off")
           if enabled else
           InlineKeyboardButton(text=f"🔔 Присылать в {settings.DIGEST_TIME}", callback_data="dg:on"))
    return InlineKeyboardMarkup(inline_keyboard=[[btn]])


async def _telemt() -> tuple:
    """(пользователи, отметка запуска движка, счётчик прощупываний)."""
    api = TelemtAPIClient()
    users = started = bad = None
    try:
        users = await api.users()
        info = (await api.system_info()).get("data") or {}
        started = str(info.get("process_started_at_epoch_secs") or "")
    except Exception as exc:
        logging.info("Сводка: движок не ответил: %s", exc)
    try:
        async with http.shared_httpx(timeout=5) as c:
            text = (await c.get(settings.PROMETHEUS_METRICS_URL)).text
        m = re.search(r"^telemt_connections_bad_total\s+(\d+)", text, re.M)
        bad = int(m.group(1)) if m else None
    except Exception as exc:
        logging.info("Сводка: метрики движка не прочитаны: %s", exc)
    return users, started, bad


async def _snapshot() -> tuple[dict, dict]:
    """(снимок счётчиков, сопутствующее для этого же прохода)."""
    users, started, bad = await _telemt()
    xui = await asyncio.to_thread(sources.xui_clients)
    fw, fw_off = await asyncio.to_thread(sources.firewall)
    snap = {
        "boot": sources.boot_id(),
        "nic": sources.nic_bytes(),
        "xui": None if xui is None else {e: b for e, b, _, _ in xui},
        "telemt": None if users is None else {str(u.get("username")): int(u.get("total_octets") or 0)
                                               for u in users},
        "telemt_start": started,
        "bad": bad,
        "fw": fw,
    }
    return snap, {"users": users, "xui": xui, "fw_off": fw_off}


async def _hub_total():
    hub = beszel_client()
    if not hub.configured:
        return None
    try:
        answer = await hub.systems()
        if answer.state != "ok":
            return -1
        return len(answer.systems or [])
    except Exception as exc:
        logging.info("Сводка: хаб не ответил: %s", exc)
        return -1


async def build(now: float) -> tuple[report.Facts, dict]:
    """Собрать сводку от последнего закрытия суток до now. Ничего не сохраняет."""
    led = ledger()
    d = led.data
    a = float(d.get("last_run") or now)
    old = d.get("snap") or {}
    snap, extra = await _snapshot()

    rebooted = bool(old.get("boot")) and old.get("boot") != snap["boot"]
    restarted = bool(old.get("telemt_start")) and old.get("telemt_start") != snap["telemt_start"]

    traffic = report.delta(snap["nic"], None if rebooted else old.get("nic"))
    probes = (report.delta(snap["bad"], None if restarted else old.get("bad"))
              if snap["bad"] is not None else None)
    fw = report.delta(snap["fw"], None if rebooted else old.get("fw")) if snap["fw"] is not None else None

    ssh = await asyncio.to_thread(sources.ssh_attempts, a, now)
    peak = d.get("peak") or {}
    f = report.Facts(
        server=settings.DIGEST_NAME or _server_name(),
        a=a, b=now, tz=settings.DIGEST_TZ,
        traffic=traffic, traffic_since_boot=rebooted,
        traffic_prev=(d.get("prev") or {}).get("traffic"),
        xui=None if snap["xui"] is None else report.per_name(snap["xui"], old.get("xui") or {}),
        telemt=None if snap["telemt"] is None else report.per_name(snap["telemt"], old.get("telemt") or {},
                                                                  restarted),
        peak=(int(peak["value"]), float(peak["at"])) if peak.get("value") else None,
        ssh=ssh, ssh_prev=(d.get("prev") or {}).get("ssh"),
        bans=await asyncio.to_thread(sources.bans, a, now),
        probes=probes, probes_hist=list(d.get("probes_hist") or []),
        firewall=fw, firewall_off=extra["fw_off"],
        watchdog=bool(settings.WATCHDOG_ENABLED),
        events=list(d.get("events") or []),
        ru=await asyncio.to_thread(sources.ru_checks, a, now),
        hub_total=await _hub_total(),
        backup=await asyncio.to_thread(sources.backup, a, now),
        maint=await asyncio.to_thread(sources.maintenance, a, now, extra["xui"], extra["users"]),
    )
    return f, snap


def _server_name() -> str:
    from telemt.handlers.common import get_server_name
    return get_server_name()


async def send_to(bot: Bot, chat_id: int, f: report.Facts) -> None:
    """
    Rich Message с таблицами — как «Сводка» и «Серверы» в этом боте; первая
    редакция шла простым текстом, и владелец по снимку 25.09.2026 назвал её
    «страшноватой». Rich не приняли — тот же разбор обычным текстом. Кнопка
    выключения есть в обоих случаях: без неё рассылку было бы нечем остановить.
    """
    kb = keyboard(ledger().enabled)
    try:
        await bot.send_rich_message(chat_id=chat_id,
                                    rich_message=InputRichMessage(html=report.render_rich(f)),
                                    reply_markup=kb)
        return
    except Exception as exc:
        logging.warning("Сводка: Rich Message не отправился (%s), шлю обычным текстом", exc)
    await bot.send_message(chat_id=chat_id, text=report.render(f), parse_mode="HTML",
                           reply_markup=kb)


async def send(bot: Bot, f: report.Facts) -> None:
    for admin_id in settings.ADMIN_IDS:
        try:
            await send_to(bot, admin_id, f)
        except Exception as exc:
            logging.warning("Сводка: не доставил админу %s: %s", admin_id, exc)


async def close_day(bot: Bot, now: float) -> None:
    led = ledger()
    f, snap = await build(now)
    led.roll(now, snap, f.traffic if not f.traffic_since_boot else None, f.ssh, f.probes)
    if led.enabled:
        await send(bot, f)


async def tick(bot: Bot, now: float | None = None) -> None:
    now = time.time() if now is None else now
    led = ledger()
    if led.note_peak(await asyncio.to_thread(sources.established, sources.peak_ports()), now):
        led.save()
    last = led.data.get("last_run")
    if not last:
        # Первый запуск: закрыть нечего — только запомнить, откуда считать.
        snap, _ = await _snapshot()
        led.roll(now, snap, None, None, None)
        logging.info("Сводка: первый снимок, первые сутки закроются в %s %s",
                     settings.DIGEST_TIME, settings.DIGEST_TZ)
        return
    if now >= report.next_run(float(last), settings.DIGEST_TIME, settings.DIGEST_TZ):
        await close_day(bot, now)


async def digest_loop(bot: Bot) -> None:
    # Дать боту подняться: первая сводка после рестарта не должна обгонять
    # сторожа, который в эти секунды читает своё состояние.
    await asyncio.sleep(20)
    while True:
        try:
            await tick(bot)
        except Exception as exc:
            logging.warning("Сводка: проход не удался: %s", exc)
        await asyncio.sleep(TICK)
