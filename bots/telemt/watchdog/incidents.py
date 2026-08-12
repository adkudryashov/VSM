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
"""

from dataclasses import dataclass, field
from typing import Optional

# Что вернул переход. None означает «ничего не изменилось, молчим».
FIRE = "fire"
CLEAR = "clear"


@dataclass
class Flap:
    """
    Счётчик плохих опросов подряд с порогом на срабатывание.

    threshold — сколько плохих опросов подряд нужно, чтобы поднять тревогу.
    """

    threshold: int = 3
    bad: int = 0
    firing: bool = False

    def update(self, is_bad: bool) -> Optional[str]:
        if is_bad:
            self.bad += 1
            if self.bad >= self.threshold and not self.firing:
                self.firing = True
                return FIRE
            return None
        # Хороший опрос: счётчик обнуляем всегда, отбой даём только если
        # тревога действительно висела.
        self.bad = 0
        if self.firing:
            self.firing = False
            return CLEAR
        return None

    def to_dict(self) -> dict:
        return {"bad": self.bad, "firing": self.firing}

    @classmethod
    def from_dict(cls, data: dict, threshold: int) -> "Flap":
        return cls(
            threshold=threshold,
            bad=int(data.get("bad", 0)),
            firing=bool(data.get("firing", False)),
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
    ip: IPWatch = field(default_factory=IPWatch)
    started_at: Marker = field(default_factory=Marker)
    config_hash: Marker = field(default_factory=Marker)
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
            "ip": self.ip.to_dict(),
            "started_at": self.started_at.to_dict(),
            "config_hash": self.config_hash.to_dict(),
            "muted_until": self.muted_until,
        }

    @classmethod
    def from_dict(cls, data: dict, threshold: int) -> "WatchState":
        data = data or {}
        return cls(
            engine=Flap.from_dict(data.get("engine", {}), threshold),
            writers=Flap.from_dict(data.get("writers", {}), threshold),
            ru_access=Flap.from_dict(data.get("ru_access", {}), threshold),
            ip=IPWatch.from_dict(data.get("ip", {})),
            started_at=Marker.from_dict(data.get("started_at", {})),
            config_hash=Marker.from_dict(data.get("config_hash", {})),
            muted_until=float(data.get("muted_until", 0.0)),
        )
