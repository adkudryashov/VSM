"""
Цикл сторожа: опрашивает движок, сравнивает с прежним состоянием, шлёт тревоги.

Весь ввод-вывод здесь; решения — в incidents.py, проверка из РФ — в
globalping.py. Разделение не ради красоты: логику переходов так можно прогнать
целиком без сервера и без Telegram.

ЧТО СТОРОЖИТСЯ И ПОЧЕМУ ИМЕННО ЭТО:

  движок недоступен      API не отвечает — прокси либо лёг, либо потерял API
  движок перезапустился  process_started_at сменился без нашего ведома
  писатели просели       некому писать в Telegram: клиенты подключатся и зависнут
  конфиг движка изменён  telemt.toml переписали мимо VSM
  адрес сервера сменился все выданные клиентам ссылки стали недействительны
  доступность из РФ      единственный сигнал про вход; остальное меряет выход

Про конфиг отдельно. На сервере есть процессы с правом переписать
/etc/telemt/telemt.toml от root — например, панель MTProxyL, если её ставили.
Подмена там меняет параметры маскировки, и снаружи это выглядит не как авария,
а как исправно работающий, но заметный сервер. Заметить такое можно только по
факту: движок сам отдаёт config_hash, его и сверяем.
"""

import asyncio
import html
import json
import logging
import time
from pathlib import Path

from aiogram import Bot

from config import settings, DATA_DIR
from telemt.api.client import TelemtAPIClient
from telemt.watchdog import globalping
from telemt.watchdog.incidents import CLEAR, FIRE, WatchState

STATE_PATH = Path(DATA_DIR) / "watchdog.json"


def _load_state() -> WatchState:
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as fh:
            return WatchState.from_dict(json.load(fh), settings.WATCHDOG_FAILURES_BEFORE_ALERT)
    except FileNotFoundError:
        return WatchState.from_dict({}, settings.WATCHDOG_FAILURES_BEFORE_ALERT)
    except Exception as exc:
        # Битый файл состояния не должен мешать сторожу работать: начинаем
        # с чистого листа, но говорим об этом вслух.
        logging.warning("Сторож: не прочитал %s (%s) — начинаю с чистого состояния", STATE_PATH, exc)
        return WatchState.from_dict({}, settings.WATCHDOG_FAILURES_BEFORE_ALERT)


def _save_state(state: WatchState) -> None:
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(state.to_dict(), fh, ensure_ascii=False)
        tmp.replace(STATE_PATH)
    except Exception as exc:
        logging.warning("Сторож: не сохранил состояние: %s", exc)


class Watchdog:
    def __init__(self):
        self.state = _load_state()
        self.api = TelemtAPIClient()
        # Последний вердикт по доступности из РФ — его показывает /watch.
        self.ru_last: dict | None = None
        self.ru_error: str = ""
        self.ru_checked_at: float = 0.0
        self._ru_next: float = 0.0
        self._lock = asyncio.Lock()

    # ---------------------------------------------------------------- отправка
    async def _notify(self, bot: Bot, text: str, force: bool = False) -> None:
        """
        Рассылает тревогу администраторам.

        Заглушение проверяется здесь, а не в местах вызова: иначе каждый новый
        вид тревоги пришлось бы не забыть обернуть, и однажды забыли бы.
        """
        if not force and self.state.muted(time.time()):
            logging.info("Сторож: тревога заглушена, не отправляю: %s", text[:60])
            return
        for admin_id in settings.ADMIN_IDS:
            try:
                await bot.send_message(chat_id=admin_id, text=text, parse_mode="HTML")
            except Exception as exc:
                logging.warning("Сторож: не доставил админу %s: %s", admin_id, exc)

    # ------------------------------------------------------------------ опрос
    async def poll_once(self, bot: Bot) -> None:
        """Один проход. Исключения не выпускает: цикл обязан пережить всё."""
        async with self._lock:
            await self._poll_engine(bot)
            await self._poll_ip(bot)
            await self._maybe_check_ru(bot)
            _save_state(self.state)

    async def _poll_engine(self, bot: Bot) -> None:
        info = None
        writers = None
        reachable = True
        try:
            info = (await self.api.system_info()).get("data") or {}
            writers = (await self.api.me_writers()).get("data") or {}
        except Exception as exc:
            reachable = False
            logging.info("Сторож: движок не ответил: %s", exc)

        event = self.state.engine.update(is_bad=not reachable)
        if event == FIRE:
            await self._notify(bot, "🚨 <b>ДВИЖОК НЕДОСТУПЕН</b>\n"
                                    "API telemt не отвечает — прокси не обслуживает клиентов.")
        elif event == CLEAR:
            await self._notify(bot, "✅ <b>ДВИЖОК СНОВА НА СВЯЗИ</b>")

        if not reachable:
            # Дальше сравнивать нечего: отсутствие данных — не смена данных.
            return

        started = str(info.get("process_started_at_epoch_secs") or "")
        if self.state.started_at.update(started):
            await self._notify(bot, "♻️ <b>Движок перезапустился</b>\n"
                                    f"Версия: {html.escape(str(info.get('version', '?')))}")

        config_hash = str(info.get("config_hash") or "")
        if self.state.config_hash.update(config_hash):
            await self._notify(
                bot,
                "📝 <b>ИЗМЕНИЛСЯ КОНФИГ ДВИЖКА</b>\n"
                f"Файл: <code>{html.escape(str(info.get('config_path', '?')))}</code>\n"
                "Если правку делали не вы — проверьте параметры маскировки: "
                "снаружи подмена выглядит не как авария, а как заметный сервер.",
            )

        summary = (writers or {}).get("summary") or {}
        coverage = summary.get("fresh_coverage_pct")
        if coverage is None:
            coverage = summary.get("coverage_pct")
        if coverage is not None:
            low = float(coverage) < float(settings.WATCHDOG_COVERAGE_FLOOR_PCT)
            event = self.state.writers.update(is_bad=low)
            if event == FIRE:
                await self._notify(
                    bot,
                    "🚨 <b>ПРОСЕЛИ ПИСАТЕЛИ В TELEGRAM</b>\n"
                    f"Покрытие: {float(coverage):.0f}% "
                    f"(порог {float(settings.WATCHDOG_COVERAGE_FLOOR_PCT):.0f}%)\n"
                    f"Живых: {summary.get('alive_writers', '?')} из "
                    f"{summary.get('required_writers', '?')} нужных.\n"
                    "Клиенты будут подключаться и зависать.",
                )
            elif event == CLEAR:
                await self._notify(bot, "✅ <b>ПИСАТЕЛИ ВОССТАНОВЛЕНЫ</b>\n"
                                        f"Покрытие: {float(coverage):.0f}%")

    async def _poll_ip(self, bot: Bot) -> None:
        observed = await globalping.public_ip()
        previous = self.state.ip.update(observed)
        if previous:
            await self._notify(
                bot,
                "📍 <b>СМЕНИЛСЯ ВНЕШНИЙ АДРЕС СЕРВЕРА</b>\n"
                f"Было: <code>{html.escape(previous)}</code>\n"
                f"Стало: <code>{html.escape(self.state.ip.known)}</code>\n"
                "Выданные клиентам ссылки на прежний адрес больше не работают.",
            )

    # ------------------------------------------------------- доступность из РФ
    def _ru_target(self) -> tuple[str, int, str]:
        host = settings.RU_CHECK_HOST or self.state.ip.known
        return host, int(settings.RU_CHECK_PORT or 0), settings.RU_CHECK_SNI

    async def run_ru_check(self, bot: Bot, manual: bool = False) -> str:
        """
        Прогоняет проверку доступности. Возвращает текст для человека.

        manual=True — вызов из команды /check: тогда результат возвращается
        спрашивающему даже при заглушённых тревогах.
        """
        host, port, sni = self._ru_target()
        if not host or not port:
            self.ru_error = "не задан адрес или порт прокси"
            return f"⚠️ Проверка не настроена: {self.ru_error}."
        try:
            verdict = await globalping.check(
                host, port, sni, int(settings.RU_CHECK_PROBES),
                token=settings.RU_CHECK_TOKEN,
            )
        except globalping.RateLimited as exc:
            self.ru_error = str(exc)
            # Бюджет исчерпан — переносим следующую попытку на час, иначе
            # каждый тик будет тратить запрос впустую и продлевать блокировку.
            self._ru_next = time.time() + 3600
            return f"⚠️ {html.escape(str(exc))}"
        except Exception as exc:
            self.ru_error = str(exc)
            return f"⚠️ Проверка не удалась: {html.escape(str(exc))}"

        self.ru_error = ""
        self.ru_last = verdict
        self.ru_checked_at = time.time()

        low = verdict["pct"] < float(settings.RU_CHECK_FLOOR_PCT)
        event = self.state.ru_access.update(is_bad=low)
        if event == FIRE:
            await self._notify(
                bot,
                "🚨 <b>ПАДЕНИЕ ДОСТУПНОСТИ ИЗ РОССИИ</b>\n"
                f"Дошло {verdict['success']} из {verdict['total']} зондов "
                f"({verdict['pct']:.0f}%).\n"
                + self._reasons_block(verdict),
            )
        elif event == CLEAR:
            await self._notify(
                bot,
                "✅ <b>ДОСТУПНОСТЬ ИЗ РОССИИ ВОССТАНОВЛЕНА</b>\n"
                f"Дошло {verdict['success']} из {verdict['total']} зондов "
                f"({verdict['pct']:.0f}%).",
            )
        return self._render_ru(verdict)

    @staticmethod
    def _reasons_block(verdict: dict) -> str:
        reasons = verdict.get("reasons") or {}
        if not reasons:
            return ""
        lines = ["<b>Почему не дошли:</b>"]
        for reason, count in sorted(reasons.items(), key=lambda kv: -kv[1])[:4]:
            lines.append(f"  • {html.escape(reason)} — {count}")
        return "\n".join(lines)

    @staticmethod
    def _render_ru(verdict: dict) -> str:
        mark = "✅" if verdict["pct"] >= float(settings.RU_CHECK_FLOOR_PCT) else "🚨"
        text = (f"{mark} <b>Доступность из РФ — {verdict['pct']:.0f}%</b>\n"
                f"{verdict['success']} из {verdict['total']} зондов\n")
        block = Watchdog._reasons_block(verdict)
        return text + ("\n" + block if block else "")

    async def _maybe_check_ru(self, bot: Bot) -> None:
        if not settings.RU_CHECK_ENABLED:
            return
        now = time.time()
        if now < self._ru_next:
            return
        self._ru_next = now + max(int(settings.RU_CHECK_INTERVAL_MINUTES), 1) * 60
        await self.run_ru_check(bot)

    # ------------------------------------------------------------------ вывод
    def render_status(self) -> str:
        now = time.time()
        lines = ["🛡 <b>Сторож telemt</b>", ""]

        lines.append("🚨 Тревога: движок недоступен" if self.state.engine.firing
                     else "✅ Движок отвечает")
        lines.append("🚨 Тревога: писатели просели" if self.state.writers.firing
                     else "✅ Писатели в норме")

        if self.state.ip.known:
            lines.append(f"📍 Внешний адрес: <code>{html.escape(self.state.ip.known)}</code>")

        lines.append("")
        if not settings.RU_CHECK_ENABLED:
            lines.append("🇷🇺 Доступность из РФ: проверка выключена")
        elif self.ru_error:
            lines.append(f"🇷🇺 Доступность из РФ: {html.escape(self.ru_error)}")
        elif self.ru_last:
            ago = int((now - self.ru_checked_at) / 60)
            lines.append(self._render_ru(self.ru_last).rstrip())
            lines.append(f"<i>проверено {ago} мин назад</i>")
        else:
            lines.append("🇷🇺 Доступность из РФ: проверок ещё не было")

        if self.state.muted(now):
            if self.state.muted_until < 0:
                lines.append("\n🔕 Тревоги заглушены до отмены — /unmute")
            else:
                left = int((self.state.muted_until - now) / 60)
                lines.append(f"\n🔕 Тревоги заглушены ещё {left} мин — /unmute")
        return "\n".join(lines)

    def mute(self, minutes: int) -> str:
        """minutes <= 0 — заглушить до отмены."""
        if minutes <= 0:
            self.state.muted_until = -1.0
            text = "🔕 Тревоги заглушены до отмены. Вернуть — /unmute"
        else:
            self.state.muted_until = time.time() + minutes * 60
            text = f"🔕 Тревоги заглушены на {minutes} мин. Вернуть — /unmute"
        _save_state(self.state)
        return text

    def unmute(self) -> str:
        self.state.muted_until = 0.0
        _save_state(self.state)
        return "🔔 Тревоги снова включены."


# Один экземпляр на процесс: и цикл, и обработчики команд смотрят в одно
# состояние. Иначе /watch показывал бы не то, по чему сторож принимает решения.
watchdog = Watchdog()


async def watchdog_loop(bot: Bot) -> None:
    if not settings.WATCHDOG_ENABLED:
        logging.info("Сторож telemt выключен (WATCHDOG_ENABLED=false).")
        return
    logging.info(
        "Сторож telemt включён: интервал %s с, порог тревоги %s опросов, проверка из РФ %s",
        settings.WATCHDOG_INTERVAL_SECONDS,
        settings.WATCHDOG_FAILURES_BEFORE_ALERT,
        "включена" if settings.RU_CHECK_ENABLED else "выключена",
    )
    # Пауза на старте: бот ещё поднимается, а движок после совместного
    # рестарта отвечает не сразу — без неё первый же опрос дал бы ложный промах.
    await asyncio.sleep(15)
    while True:
        try:
            await watchdog.poll_once(bot)
        except Exception as exc:
            logging.error("Сторож: ошибка цикла: %s", exc)
        await asyncio.sleep(max(int(settings.WATCHDOG_INTERVAL_SECONDS), 10))
