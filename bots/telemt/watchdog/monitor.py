"""
Цикл сторожа: опрашивает движок, сравнивает с прежним состоянием, шлёт тревоги.

Весь ввод-вывод здесь; решения — в incidents.py, проверка из РФ — в
globalping.py. Разделение не ради красоты: логику переходов так можно прогнать
целиком без сервера и без Telegram.

ЧТО СТОРОЖИТСЯ И ПОЧЕМУ ИМЕННО ЭТО:

  движок недоступен      API не отвечает — прокси либо лёг, либо потерял API
  движок перезапустился  process_started_at сменился без нашего ведома
  писатели просели       некому писать в Telegram: клиенты подключатся и зависнут
  жёсткие отказы выхода  движок не может дозвониться до Telegram — сломан выход
  домен не на этот сервер клиенты идут по старому адресу: переехали, забыли DNS
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
from telemt.watchdog import globalping, upstreams
from telemt.watchdog.incidents import CLEAR, FIRE, REPEAT, WatchState

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
        # Снимок накопительных счётчиков движка. В памяти, не на диске: после
        # перезапуска бота пропускается одно сравнение, и это дешевле, чем
        # тащить эти числа через миграции файла состояния.
        self.hard = upstreams.HardFailWatch()
        # Последняя посчитанная дельта и последняя сверка DNS — только для
        # показа в /watch, на решения не влияют.
        self.hard_last: upstreams.Delta = upstreams.Delta()
        self.dns_addrs: list = []
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

    async def _fire_or_clear(self, bot: Bot, event, flap, *, fire: str, clear: str) -> None:
        """
        Один разбор события для всех тревог сразу.

        FIRE и REPEAT шлют один и тот же разбор — меняется только шапка. Писать
        для напоминания отдельный, укороченный текст нельзя: через полчаса
        человек уже не помнит подробностей из первого сообщения, а лезть за ним
        вверх по чату он не станет.
        """
        if event == FIRE:
            await self._notify(bot, fire)
        elif event == REPEAT:
            minutes = flap.duration()
            head = (f"⏳ <b>Авария продолжается {minutes} мин</b>\n\n" if minutes
                    else "⏳ <b>Авария продолжается</b>\n\n")
            await self._notify(bot, head + fire)
        elif event == CLEAR:
            minutes = flap.duration()
            await self._notify(bot, clear + (f"\nДлилась {minutes} мин." if minutes else ""))

    # ------------------------------------------------------------------ опрос
    async def poll_once(self, bot: Bot) -> None:
        """Один проход. Исключения не выпускает: цикл обязан пережить всё."""
        async with self._lock:
            await self._poll_engine(bot)
            await self._poll_ip(bot)
            # После _poll_ip: сверка домена сравнивает его с адресом сервера, а
            # тот становится известен именно там.
            await self._poll_dns(bot)
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

        await self._fire_or_clear(
            bot, self.state.engine.update(is_bad=not reachable), self.state.engine,
            fire="🚨 <b>ДВИЖОК НЕДОСТУПЕН</b>\n"
                 "API telemt не отвечает — прокси не обслуживает клиентов.",
            clear="✅ <b>ДВИЖОК СНОВА НА СВЯЗИ</b>",
        )

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
            await self._fire_or_clear(
                bot, self.state.writers.update(is_bad=low), self.state.writers,
                fire="🚨 <b>ПРОСЕЛИ ПИСАТЕЛИ В TELEGRAM</b>\n"
                     f"Покрытие: {float(coverage):.0f}% "
                     f"(порог {float(settings.WATCHDOG_COVERAGE_FLOOR_PCT):.0f}%)\n"
                     f"Живых: {summary.get('alive_writers', '?')} из "
                     f"{summary.get('required_writers', '?')} нужных.\n"
                     "Клиенты будут подключаться и зависать.",
                clear="✅ <b>ПИСАТЕЛИ ВОССТАНОВЛЕНЫ</b>\n"
                      f"Покрытие: {float(coverage):.0f}%",
            )

        await self._poll_hard_fails(bot, started)

    async def _poll_hard_fails(self, bot: Bot, started: str) -> None:
        """
        Жёсткие отказы исходящих подключений. Разбор — в upstreams.py.

        Отдельный запрос и отдельный try: этот эндпоинт появился в движке позже
        остальных, и его отсутствие не должно объявлять движок недоступным.
        """
        try:
            payload = await self.api.upstreams()
        except Exception as exc:
            logging.info("Сторож: статистика апстримов не прочитана: %s", exc)
            return

        delta = self.hard.update(upstreams.extract(payload), started)
        self.hard_last = delta
        if not delta.has_rate:
            # Измерения не было: первый опрос, перезапуск движка или ни одной
            # попытки за интервал. Состояние тревоги НЕ трогаем — иначе на
            # простаивающем сервере «ноль отказов» молча погасил бы аварию.
            return

        threshold = float(settings.WATCHDOG_HARD_FAIL_PCT)
        await self._fire_or_clear(
            bot, self.state.hard_fails.update(is_bad=delta.hard_pct > threshold),
            self.state.hard_fails,
            fire="🚨 <b>СЛОМАН ВЫХОД К TELEGRAM</b>\n"
                 f"Отказов без повтора: {delta.hard_pct:.0f}% "
                 f"(порог {threshold:.0f}%)\n"
                 f"За интервал: {delta.hard} из {delta.attempts} попыток.\n"
                 "Движок не может дозвониться до серверов Telegram.",
            clear="✅ <b>ВЫХОД К TELEGRAM ВОССТАНОВЛЕН</b>\n"
                  f"Отказов без повтора: {delta.hard_pct:.0f}%",
        )

    @staticmethod
    def _dns_host() -> str:
        """
        Домен, который обязан вести на этот сервер.

        RU_CHECK_HOST — адрес, по которому подключаются клиенты, но он часто
        пуст (тогда проверка берёт свой внешний адрес) или задан голым IP.
        В этом случае сверяем домен маскировки: он же домен панели, и он тоже
        обязан указывать сюда — иначе не обновится сертификат, которым прокси
        прикрывается, и перестанет открываться панель.

        Пусто — сверять нечего, сигнал молчит. Так и должно быть на установке,
        где клиентам раздают голый IP.
        """
        for candidate in (settings.RU_CHECK_HOST, settings.RU_CHECK_SNI):
            if candidate and not globalping.is_ip(candidate):
                return candidate
        return ""

    async def _poll_dns(self, bot: Bot) -> None:
        """
        Ведёт ли домен подключения на этот сервер.

        Класс аварии, который не виден больше ничем: переехали на новый VPS,
        забыли переставить DNS. Движок здоров, писатели на месте, зонды даже
        могут доходить — но приходят они на чужой сервер.

        Ничего не стоит: обычный резолв, наружу ни одного лишнего пакета.
        Поэтому работает и при выключенной проверке доступности.
        """
        host = self._dns_host()
        server_ip = self.state.ip.known
        addrs = await globalping.resolve_host(host) if host else []
        self.dns_addrs = addrs

        if not addrs or not server_ip:
            # Сверять не с чем: цель задана голым IP, резолв не удался или свой
            # адрес ещё не известен. Это не расхождение — молчим и не трогаем
            # состояние, чтобы недоступность DNS не дала отбоя настоящей тревоге.
            return

        await self._fire_or_clear(
            bot, self.state.dns.update(is_bad=server_ip not in addrs), self.state.dns,
            fire="🚨 <b>ДОМЕН НЕ ВЕДЁТ НА ЭТОТ СЕРВЕР</b>\n"
                 f"Домен: <code>{html.escape(host)}</code>\n"
                 f"Ведёт на: <code>{html.escape(', '.join(addrs))}</code>\n"
                 f"Сервер: <code>{html.escape(server_ip)}</code>\n"
                 "Клиенты идут не сюда. Прокси при этом полностью исправен.",
            clear="✅ <b>ДОМЕН СНОВА ВЕДЁТ НА ЭТОТ СЕРВЕР</b>\n"
                  f"<code>{html.escape(host)}</code> → <code>{html.escape(server_ip)}</code>",
        )

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

        probes = int(settings.RU_CHECK_PROBES)
        has_token = bool(settings.RU_CHECK_TOKEN)

        # Кулдаун — только на ручные. Автоматические идут по расписанию, и
        # второй ограничитель им ни к чему; а вот человек, увидевший тревогу,
        # жмёт /check несколько раз подряд, и это нормальное поведение.
        if manual:
            wait = self.state.quota.manual_ready_in()
            if wait:
                return f"⏳ Проверку только что запускали. Повторите через {wait} с."

        denial = self.state.quota.can_spend(probes, has_token)
        if denial:
            self.ru_error = denial
            _save_state(self.state)
            return f"⚠️ {html.escape(denial)}"

        if manual:
            self.state.quota.note_manual()

        try:
            verdict = await globalping.check(
                host, port, sni, probes, token=settings.RU_CHECK_TOKEN,
            )
        except globalping.RateLimited as exc:
            self.ru_error = str(exc)
            # Слово сервиса важнее нашей арифметики: если он назвал срок —
            # берём его, иначе отступаем на час. Блокировка сохраняется на
            # диск, иначе перезапуск бота снова упрётся в отказ и продлит его.
            self.state.quota.block_for(exc.retry_after or 3600)
            self._ru_next = time.time() + (exc.retry_after or 3600)
            _save_state(self.state)
            return f"⚠️ {html.escape(str(exc))}"
        except Exception as exc:
            self.ru_error = str(exc)
            return f"⚠️ Проверка не удалась: {html.escape(str(exc))}"

        # Списываем по фактически задействованным зондам — см. quota.py.
        self.state.quota.record(int(verdict.get("charged") or probes))
        self.ru_error = ""
        self.ru_last = verdict
        self.ru_checked_at = time.time()
        _save_state(self.state)

        low = verdict["pct"] < float(settings.RU_CHECK_FLOOR_PCT)
        await self._fire_or_clear(
            bot, self.state.ru_access.update(is_bad=low), self.state.ru_access,
            fire="🚨 <b>ПАДЕНИЕ ДОСТУПНОСТИ ИЗ РОССИИ</b>\n"
                 f"Дошло {verdict['success']} из {verdict['total']} зондов "
                 f"({verdict['pct']:.0f}%).\n" + self._reasons_block(verdict),
            clear="✅ <b>ДОСТУПНОСТЬ ИЗ РОССИИ ВОССТАНОВЛЕНА</b>\n"
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
        """
        Светофор ПОКАЗЫВАЕТ, но не будит. Жёлтый — «посмотри, когда будешь
        смотреть»: доступность просела, но выше порога тревоги. Уведомление
        по-прежнему шлётся только на красном, и добавление цвета не прибавило
        ни одного сообщения в чат.
        """
        floor = float(settings.RU_CHECK_FLOOR_PCT)
        mark = globalping.LEVEL_MARKS[globalping.level(verdict["pct"], floor)]
        text = (f"{mark} <b>Доступность из РФ — {verdict['pct']:.0f}%</b>\n"
                f"{verdict['success']} из {verdict['total']} зондов\n")
        block = Watchdog._reasons_block(verdict)
        return text + ("\n" + block if block else "")

    def manual_block_reason(self) -> str:
        """
        Почему ручную проверку нельзя запускать прямо сейчас; пусто — можно.

        Нужна отдельно от run_ru_check, хотя тот проверяет то же самое: иначе
        обработчик успевал написать «запускаю проверку» и следом «нельзя», и
        первое сообщение оставалось враньём. Настоящий запрет всё равно стоит
        в run_ru_check — эта функция только избавляет от лишней строки.
        """
        wait = self.state.quota.manual_ready_in()
        if wait:
            return f"⏳ Проверку только что запускали. Повторите через {wait} с."
        denial = self.state.quota.can_spend(
            int(settings.RU_CHECK_PROBES), bool(settings.RU_CHECK_TOKEN))
        return f"⚠️ {html.escape(denial)}" if denial else ""

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

        # Выход к Telegram. Показываем живую долю жёстких отказов — по ней
        # видно, насколько порог далёк от действительности на этом сервере.
        if self.state.hard_fails.firing:
            lines.append(f"🚨 Тревога: сломан выход — отказов без повтора "
                         f"{self.hard_last.hard_pct:.0f}%")
        elif self.hard_last.has_rate:
            lines.append(f"✅ Выход к Telegram: отказов без повтора "
                         f"{self.hard_last.hard_pct:.0f}%")
            # Справка о качестве маршрутов. НЕ признак аварии: движок пробует
            # несколько точек и берёт первую ответившую, поэтому здесь штатно
            # бывают десятки процентов при полностью исправной связи.
            lines.append(f"   <i>повторов подключения {self.hard_last.fail_pct:.0f}% "
                         f"— это норма, не авария</i>")

        if self.state.dns.firing:
            lines.append("🚨 Тревога: домен не ведёт на этот сервер")
        elif self.dns_addrs:
            lines.append("✅ Домен ведёт на этот сервер")

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

        if settings.RU_CHECK_ENABLED:
            lines.append(f"<i>{html.escape(self.state.quota.render(bool(settings.RU_CHECK_TOKEN), now))}</i>")

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
