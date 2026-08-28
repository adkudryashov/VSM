"""
Решения сторожа: когда бить тревогу и когда объявлять отбой.

Здесь нет ни сети, ни Telegram, ни файлов — только переходы состояний. Так их
можно прогнать целиком без сервера, а весь ввод-вывод живёт в monitor.py.

ПОЧЕМУ ГИСТЕРЕЗИС. По одному сорвавшемуся опросу судить нельзя: движок
перезапускается за секунды, и бот, реагирующий на первый промах, превращается
в источник шума — а на шум перестают смотреть, и он пропускает настоящую
аварию. Тревога поднимается после N плохих опросов подряд, отбой даётся сразу
на первом хорошем: пропустить восстановление не страшно, а вот застрять в
состоянии «всё плохо» после починки — страшно.

ПОЧЕМУ ОТБОЙ ТОЛЬКО ПОСЛЕ ТРЕВОГИ. Пара «упало — поднялось» обязана быть
именно парой. Сообщение «восстановлено» без предшествующего «упало» читается
как авария, которую владелец проспал, и заставляет лезть на сервер зря.

ПОЧЕМУ ТРЕВОГА ПОВТОРЯЕТСЯ. Одно сообщение в начале аварии — это сообщение,
которое можно проспать, пролистать или потерять под чужой перепиской. Дальше
чат молчит, и молчание неотличимо от «всё в порядке». Поэтому пока авария
висит, о ней напоминают раз в полчаса. Полчаса, а не интервал опроса: при
затяжной блокировке чат превратился бы в будильник каждую минуту, и тогда
перестают замечать уже все тревоги разом.
"""

import time
from dataclasses import dataclass, field
from typing import Optional

from telemt.watchdog.quota import Quota

# Что вернул переход. None означает «ничего не изменилось, молчим».
FIRE = "fire"
CLEAR = "clear"
REPEAT = "repeat"

# Как часто напоминать о продолжающейся аварии.
REPEAT_SECONDS = 30 * 60


@dataclass
class Flap:
    """
    Счётчик плохих опросов подряд с порогом на срабатывание.

    threshold — сколько плохих опросов подряд нужно, чтобы поднять тревогу.
    """

    threshold: int = 3
    bad: int = 0
    firing: bool = False
    # Когда тревога поднялась и когда о ней в последний раз сообщали.
    # since не обнуляется при отбое: сообщение о восстановлении должно сказать,
    # сколько авария длилась, а читают его уже после перехода.
    since: float = 0.0
    last_notify: float = 0.0
    # Когда пришёл ПЕРВЫЙ плохой опрос — то есть когда авария началась на самом
    # деле, а не когда мы решились о ней сказать. Разница равна гистерезису и
    # на замере со стенда составила три минуты: покрытие писателей просело в
    # 11:45:00, а тревога ушла в 11:47:52. Считать длительность от тревоги
    # значит занижать её ровно на это время и вводить владельца в заблуждение
    # при разборе: «длилась 2 минуты» вместо настоящих пяти.
    #
    # None, а не 0.0: ноль — это законная отметка времени, и отличить «аварии
    # не было» от «авария началась в нулевую секунду» через ложность значения
    # невозможно. В бою эпоха нулём не бывает, но проверка на этом спотыкалась,
    # и оставлять ловушку из-за того, что она редко срабатывает, незачем.
    bad_since: Optional[float] = None

    def update(self, is_bad: bool, now: Optional[float] = None) -> Optional[str]:
        now = time.time() if now is None else now

        if is_bad:
            if self.bad == 0:
                self.bad_since = now
            self.bad += 1
            if self.bad >= self.threshold and not self.firing:
                self.firing = True
                self.since = now
                self.last_notify = now
                return FIRE
            if self.firing and now - self.last_notify >= REPEAT_SECONDS:
                self.last_notify = now
                return REPEAT
            return None

        # Хороший опрос: счётчик обнуляем всегда, отбой даём только если
        # тревога действительно висела.
        self.bad = 0
        if self.firing:
            self.firing = False
            self.last_notify = now
            return CLEAR
        return None

    def duration(self, now: Optional[float] = None) -> int:
        """
        Сколько минут длится (или длилась) авария — от первого плохого опроса,
        а не от момента тревоги.

        Ноль — начало неизвестно: так бывает у состояния, сохранённого прежней
        версией сторожа, где этих полей ещё не было.
        """
        start = self.bad_since
        if start is None:
            # Состояние от прежней версии сторожа: bad_since там не было.
            # Тогда считаем от тревоги — это занижает длительность, но лучше,
            # чем не показать ничего.
            start = self.since or None
        if start is None:
            return 0
        now = time.time() if now is None else now
        return max(int((now - start) / 60), 0)

    def to_dict(self) -> dict:
        return {"bad": self.bad, "firing": self.firing, "since": self.since,
                "last_notify": self.last_notify, "bad_since": self.bad_since}

    @classmethod
    def from_dict(cls, data: dict, threshold: int) -> "Flap":
        raw_bad_since = data.get("bad_since")
        return cls(
            threshold=threshold,
            bad=int(data.get("bad", 0)),
            firing=bool(data.get("firing", False)),
            since=float(data.get("since", 0.0) or 0.0),
            last_notify=float(data.get("last_notify", 0.0) or 0.0),
            bad_since=None if raw_bad_since is None else float(raw_bad_since),
        )


@dataclass
class IPWatch:
    """
    Смена внешнего адреса — с подтверждением на следующем опросе.

    Сервисы определения адреса стоят за CDN и изредка отвечают с другого
    узла — с честным успехом, просто другим адресом. Без подтверждения бот
    сообщал бы о переезде сервера, которого не было, а такое сообщение
    поднимает владельца ночью.

    Поэтому новый адрес сначала попадает в pending и объявляется сменой только
    когда повторится. Первый увиденный адрес — знакомство, о нём молчим.
    """

    known: str = ""
    pending: str = ""

    def update(self, observed: str) -> Optional[str]:
        """Возвращает прежний адрес, если смена подтвердилась, иначе None."""
        if not observed:
            # Не смогли узнать адрес — это не смена адреса. Копившееся
            # подтверждение сбрасываем: цепочка прервалась.
            self.pending = ""
            return None
        if not self.known:
            self.known = observed
            self.pending = ""
            return None
        if observed == self.known:
            self.pending = ""
            return None
        if self.pending != observed:
            self.pending = observed
            return None
        previous = self.known
        self.known = observed
        self.pending = ""
        return previous

    def to_dict(self) -> dict:
        return {"known": self.known, "pending": self.pending}

    @classmethod
    def from_dict(cls, data: dict) -> "IPWatch":
        return cls(known=str(data.get("known", "")), pending=str(data.get("pending", "")))


@dataclass
class Marker:
    """
    Слежение за значением, которое меняться не должно: отметка запуска движка
    и хеш его конфига.

    Первое значение запоминается молча — иначе бот кричал бы при каждом
    собственном старте.
    """

    value: str = ""

    def update(self, observed: str) -> Optional[str]:
        """Возвращает прежнее значение, если оно изменилось, иначе None."""
        if not observed:
            return None
        if not self.value:
            self.value = observed
            return None
        if observed == self.value:
            return None
        previous = self.value
        self.value = observed
        return previous

    def to_dict(self) -> dict:
        return {"value": self.value}

    @classmethod
    def from_dict(cls, data: dict) -> "Marker":
        return cls(value=str(data.get("value", "")))


@dataclass
class WatchState:
    """
    Всё состояние сторожа. Переживает перезапуск бота через monitor.save_state.

    Без сохранения бот после рестарта заново «обнаруживал» бы и перезапуск
    движка, и текущий адрес, и уже висящую аварию — то есть слал бы тревогу на
    каждый свой рестарт. У мониторинга панелей 3x-ui состояние живёт только в
    памяти, и там этот недостаток есть; здесь его повторять не стали.
    """

    engine: Flap = field(default_factory=Flap)
    writers: Flap = field(default_factory=Flap)
    ru_access: Flap = field(default_factory=Flap)
    # Чужой вердикт доступности перестал обновляться — то есть встал
    # таймер MTProxyL, и про вход мы больше ничего не знаем. Порог один
    # опрос, а не три, как у остальных: условие уже сглажено временем
    # (RU_CHECK_STALE_MINUTES), возраст растёт только вверх и мигать не
    # может, поэтому счёт опросов сверху ничего не отфильтровал бы —
    # только отложил бы тревогу ещё на три такта.
    ru_stale: Flap = field(default_factory=lambda: Flap(threshold=1))
    # Жёсткие отказы исходящих подключений — сломан выход к Telegram.
    hard_fails: Flap = field(default_factory=Flap)
    # Домен подключения не ведёт на этот сервер — переехали, забыли DNS.
    dns: Flap = field(default_factory=Flap)
    ip: IPWatch = field(default_factory=IPWatch)
    started_at: Marker = field(default_factory=Marker)
    config_hash: Marker = field(default_factory=Marker)
    # Реестр трат Globalping. Живёт здесь, а не в памяти монитора, потому что
    # обязан пережить перезапуск: иначе после рестарта первый же опрос снова
    # упрётся в отказ сервиса и продлит блокировку.
    quota: Quota = field(default_factory=Quota)
    # Живая карточка: id сообщения статуса в каждом чате администратора.
    # Ключи строковые — такими их отдаёт JSON, и приводить их туда-сюда значит
    # однажды промахнуться типом. Переживает перезапуск, иначе после каждого
    # обновления бота в чате оставалась бы новая карточка, а старая замирала.
    cards: dict = field(default_factory=dict)
    # Отпечаток нерешённых расхождений с реестром и когда о них сообщали.
    # Хранится, чтобы после перезапуска бот не объявил заново то, о чём уже
    # написал час назад.
    drift_seen: str = ""
    drift_notify: float = 0.0
    # Момент времени (epoch), до которого тревоги не отправляются. 0 — не
    # заглушено, -1 — заглушено до отмены.
    muted_until: float = 0.0

    def muted(self, now: float) -> bool:
        if self.muted_until < 0:
            return True
        return self.muted_until > now

    def to_dict(self) -> dict:
        return {
            "engine": self.engine.to_dict(),
            "writers": self.writers.to_dict(),
            "ru_access": self.ru_access.to_dict(),
            "ru_stale": self.ru_stale.to_dict(),
            "hard_fails": self.hard_fails.to_dict(),
            "dns": self.dns.to_dict(),
            "ip": self.ip.to_dict(),
            "started_at": self.started_at.to_dict(),
            "config_hash": self.config_hash.to_dict(),
            "quota": self.quota.to_dict(),
            "cards": {str(k): int(v) for k, v in self.cards.items()},
            "drift_seen": self.drift_seen,
            "drift_notify": self.drift_notify,
            "muted_until": self.muted_until,
        }

    @classmethod
    def from_dict(cls, data: dict, threshold: int) -> "WatchState":
        data = data or {}
        return cls(
            engine=Flap.from_dict(data.get("engine", {}), threshold),
            writers=Flap.from_dict(data.get("writers", {}), threshold),
            ru_access=Flap.from_dict(data.get("ru_access", {}), threshold),
            # Порог свой, не общий из настроек — обоснование у поля выше.
            ru_stale=Flap.from_dict(data.get("ru_stale", {}), 1),
            hard_fails=Flap.from_dict(data.get("hard_fails", {}), threshold),
            dns=Flap.from_dict(data.get("dns", {}), threshold),
            ip=IPWatch.from_dict(data.get("ip", {})),
            started_at=Marker.from_dict(data.get("started_at", {})),
            config_hash=Marker.from_dict(data.get("config_hash", {})),
            quota=Quota.from_dict(data.get("quota", {})),
            cards=_cards_from(data.get("cards")),
            drift_seen=str(data.get("drift_seen", "") or ""),
            drift_notify=float(data.get("drift_notify", 0.0) or 0.0),
            muted_until=float(data.get("muted_until", 0.0)),
        )


def _cards_from(data) -> dict:
    """Битую запись пропускаем молча: потеря id карточки стоит одного лишнего
    сообщения в чате, а падение чтения состояния — всего сторожа."""
    out = {}
    for key, value in (data or {}).items():
        try:
            out[str(key)] = int(value)
        except (TypeError, ValueError):
            continue
    return out
