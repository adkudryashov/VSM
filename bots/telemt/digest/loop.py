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
# Как часто забирать попытки SSH из журнала. Журнал живёт от ~16 часов (см.
# Ledger.add_ssh) — полчаса оставляют запас в тридцать раз.
SSH_EVERY = 1800
# Как часто запоминать счётчики telemt — столько трафика может пропасть при его
# перезапуске (см. Ledger.telemt_reading). Запрос к API на петле.
TELEMT_EVERY = 300


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


def _users_bytes(users) -> dict:
    return {str(u.get("username")): int(u.get("total_octets") or 0) for u in users}


async def _telemt_reading() -> tuple:
    """(отметка запуска, байты по пользователям) без метрик; (None, None) — не ответил."""
    api = TelemtAPIClient()
    try:
        users = await api.users()
        info = (await api.system_info()).get("data") or {}
        return str(info.get("process_started_at_epoch_secs") or ""), _users_bytes(users)
    except Exception as exc:
        logging.info("Сводка: движок не ответил: %s", exc)
        return None, None


async def _snapshot() -> tuple[dict, dict]:
    """(снимок счётчиков, сопутствующее для этого же прохода)."""
    users, started, bad = await _telemt()
    xui = await asyncio.to_thread(sources.xui_clients)
    fw, fw_off = await asyncio.to_thread(sources.firewall)
    snap = {
        "boot": sources.boot_id(),
        "nic": sources.nic_bytes(),
        "xui": None if xui is None else {e: b for e, b, _, _ in xui},
        "telemt": None if users is None else _users_bytes(users),
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
    """
    Собрать сводку от последнего закрытия суток до now. Сутки не закрывает;
    сохраняет только свежее чтение счётчиков telemt — это факт, а не итог.
    """
    led = ledger()
    d = led.data
    a = float(d.get("last_run") or now)
    old = d.get("snap") or {}
    snap, extra = await _snapshot()
    if snap["telemt"] is not None:
        # Перезапуск мог случиться после последнего чтения по ходу суток.
        led.telemt_reading(snap["telemt_start"], snap["telemt"], now)

    rebooted = bool(old.get("boot")) and old.get("boot") != snap["boot"]
    restarted = bool(old.get("telemt_start")) and old.get("telemt_start") != snap["telemt_start"]

    traffic = report.delta(snap["nic"], None if rebooted else old.get("nic"))
    probes = (report.delta(snap["bad"], None if restarted else old.get("bad"))
              if snap["bad"] is not None else None)
    # Наши зонды вычитаем за то же время, за какое считан счётчик: после
    # перезапуска движка — с его старта, а не с начала суток.
    ours = None
    if probes is not None:
        since = a
        if restarted:
            try:
                since = max(a, float(snap["telemt_start"]))
            except (TypeError, ValueError):
                pass
        ours = await asyncio.to_thread(sources.our_probes, since, now)
        if ours:
            probes = max(probes - ours, 0)
    fw = report.delta(snap["fw"], None if rebooted else old.get("fw")) if snap["fw"] is not None else None

    # Накопленное за сутки плюс хвост, который ещё не забирали из журнала.
    tail = await asyncio.to_thread(sources.ssh_attempts, led.ssh_read_from(a), now)
    ssh = None if tail is None else led.ssh_counted() + tail
    peak = d.get("peak") or {}
    telemt = None
    if snap["telemt"] is not None:
        telemt = report.per_name(snap["telemt"], old.get("telemt") or {}, restarted)
        for name, b in led.telemt_banked().items():
            telemt[name] = telemt.get(name, 0) + b
    f = report.Facts(
        server=settings.DIGEST_NAME or _server_name(),
        a=a, b=now, tz=settings.DIGEST_TZ,
        traffic=traffic, traffic_since_boot=rebooted,
        clients_prev=(d.get("prev") or {}).get("clients"),
        telemt_restarted=restarted, telemt_lost=led.telemt_lost(),
        xui=None if snap["xui"] is None else report.per_name(snap["xui"], old.get("xui") or {}),
        telemt=telemt,
        peak=(int(peak["value"]), float(peak["at"])) if peak.get("value") else None,
        ssh=ssh, ssh_prev=(d.get("prev") or {}).get("ssh"),
        prev_span=(d.get("prev") or {}).get("span"),
        bans=await asyncio.to_thread(sources.bans, a, now),
        probes=probes, probes_ours=ours, probes_hist=list(d.get("foreign_hist") or []),
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
    led.roll(now, snap, report.clients_total(f) if report.telemt_exact(f) else None,
             f.ssh, f.probes)
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
    seen = float((led.data.get("tm_last") or {}).get("at") or 0)
    if now - seen >= TELEMT_EVERY:
        start, users = await _telemt_reading()
        if users is not None:
            led.telemt_reading(start, users, now)
    read_from = led.ssh_read_from(float(last))
    if now - read_from >= SSH_EVERY:
        n = await asyncio.to_thread(sources.ssh_attempts, read_from, now)
        if n is not None:
            led.add_ssh(n, now)
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
