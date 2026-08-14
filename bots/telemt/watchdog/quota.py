"""
Дисциплина трат Globalping: сколько уже потрачено, когда снова можно.

ЗАЧЕМ ОТДЕЛЬНЫЙ УЧЁТ. Кредиты считаются по зондам, окно скользящее — час.
Раньше сторож считал бюджет только арифметикой до включения (budget_fits) и на
отказ 429 отступал на час в памяти. Две дыры:

  • ручная /check не проверялась вовсе: при десяти зондах на прогон двадцать
    пять нажатий подряд сжигали часовой бюджет, и автоматическая проверка
    молча переставала работать;
  • отступ жил в памяти и терялся при перезапуске бота — после рестарта первый
    же опрос снова упирался в 429 и продлевал блокировку.

Здесь ведётся реестр фактических трат, и он сохраняется вместе с остальным
состоянием сторожа.

СПИСЫВАЕМ ПО ФАКТУ. Сервис не всегда даёт столько зондов, сколько попросили, и
списание по запрошенному лимиту занижало бы остаток — то есть сторож считал бы
себя беднее, чем он есть, и пропускал проверки без причины. В ответе на
создание измерения приходит probesCount, по нему и списываем.

СЛОВО СЕРВИСА ВАЖНЕЕ НАШЕЙ АРИФМЕТИКИ. Этот реестр — счётчик потраченного, а
не сторож бюджета. Настоящий лимит объявляет сам сервис ответом 429 с
заголовком, и блокировка по нему имеет приоритет над любыми нашими подсчётами.
"""

import time
from dataclasses import dataclass, field
from typing import Optional

# Скользящее окно учёта кредитов.
WINDOW_SECONDS = 3600

# Бюджет за окно: без токена и с токеном.
BUDGET_ANON = 250
BUDGET_TOKEN = 500

# Ручная проверка не чаще. Каждый зонд стоит кредита, а человек, увидевший
# тревогу, жмёт /check несколько раз подряд — это нормальное поведение, и оно
# не должно разорять бюджет.
MANUAL_COOLDOWN_SECONDS = 60


def retry_after_seconds(headers) -> int:
    """
    Через сколько секунд сервис разрешит снова, по его собственным заголовкам.

    Ноль означает «сервис ничего не сказал» — тогда решает вызывающий. Читаем
    оба заголовка: Retry-After стандартный, X-RateLimit-Reset отдаёт именно
    Globalping, и на 429 приходит обычно он.
    """
    if not headers:
        return 0
    for name in ("retry-after", "x-ratelimit-reset"):
        raw = headers.get(name) or headers.get(name.title())
        if raw is None:
            continue
        try:
            value = int(str(raw).strip())
        except (TypeError, ValueError):
            continue
        if value > 0:
            # Час с запасом: заведомо испорченное значение не должно запирать
            # проверку на сутки.
            return min(value, WINDOW_SECONDS * 2)
    return 0


@dataclass
class Quota:
    """
    Реестр трат и блокировок. Все методы принимают now, чтобы их можно было
    прогнать без ожидания реального времени.
    """

    # Пары (когда, сколько зондов). Хранятся плоским списком: за час их единицы.
    spends: list = field(default_factory=list)
    # Момент, до которого сервис запретил обращаться. 0 — не запрещал.
    blocked_until: float = 0.0
    # Когда в последний раз запускали проверку руками.
    last_manual: float = 0.0

    # ------------------------------------------------------------------ учёт
    def _compact(self, now: float) -> None:
        """Выкидывает траты, вышедшие из скользящего часа."""
        edge = now - WINDOW_SECONDS
        self.spends = [(ts, n) for ts, n in self.spends if ts > edge]

    def record(self, probes: int, now: Optional[float] = None) -> None:
        now = time.time() if now is None else now
        if probes > 0:
            self.spends.append((now, int(probes)))
        self._compact(now)

    def note_manual(self, now: Optional[float] = None) -> None:
        self.last_manual = time.time() if now is None else now

    def block_for(self, seconds: int, now: Optional[float] = None) -> None:
        now = time.time() if now is None else now
        self.blocked_until = max(self.blocked_until, now + max(seconds, 0))

    # --------------------------------------------------------------- вопросы
    def spent(self, now: Optional[float] = None) -> int:
        now = time.time() if now is None else now
        self._compact(now)
        return sum(n for _, n in self.spends)

    def budget(self, has_token: bool) -> int:
        return BUDGET_TOKEN if has_token else BUDGET_ANON

    def remaining(self, has_token: bool, now: Optional[float] = None) -> int:
        return max(self.budget(has_token) - self.spent(now), 0)

    def reset_in(self, now: Optional[float] = None) -> int:
        """
        Через сколько секунд освободится самая старая трата. Ноль — тратить
        нечего или окно уже пусто.
        """
        now = time.time() if now is None else now
        self._compact(now)
        if not self.spends:
            return 0
        oldest = min(ts for ts, _ in self.spends)
        return max(int(oldest + WINDOW_SECONDS - now), 0)

    def blocked(self, now: Optional[float] = None) -> bool:
        now = time.time() if now is None else now
        return self.blocked_until > now

    def blocked_for(self, now: Optional[float] = None) -> int:
        now = time.time() if now is None else now
        return max(int(self.blocked_until - now), 0)

    def manual_ready_in(self, now: Optional[float] = None) -> int:
        """Сколько секунд осталось до следующей разрешённой ручной проверки."""
        now = time.time() if now is None else now
        return max(int(self.last_manual + MANUAL_COOLDOWN_SECONDS - now), 0)

    def can_spend(self, probes: int, has_token: bool,
                  now: Optional[float] = None) -> Optional[str]:
        """
        Причина, по которой тратить нельзя, или None.

        Возвращается текст для человека, а не код: он же уходит в ответ на
        /check, и переводить его потом было бы негде.
        """
        now = time.time() if now is None else now
        if self.blocked(now):
            return (f"сервис проверки временно отказывает — "
                    f"повторите через {self.blocked_for(now) // 60 + 1} мин")
        if self.remaining(has_token, now) < probes:
            return (f"исчерпан часовой бюджет: потрачено {self.spent(now)} "
                    f"из {self.budget(has_token)}, освободится через "
                    f"{self.reset_in(now) // 60 + 1} мин")
        return None

    def render(self, has_token: bool, now: Optional[float] = None) -> str:
        """Строка для статуса сторожа."""
        now = time.time() if now is None else now
        line = (f"Квота проверок: {self.spent(now)} из {self.budget(has_token)} "
                f"за час")
        if self.spends:
            line += f", освободится через {self.reset_in(now) // 60 + 1} мин"
        if self.blocked(now):
            line += f" · сервис отказывает ещё {self.blocked_for(now) // 60 + 1} мин"
        return line

    # ------------------------------------------------------------ сохранение
    def to_dict(self) -> dict:
        return {
            "spends": [[float(ts), int(n)] for ts, n in self.spends],
            "blocked_until": self.blocked_until,
            "last_manual": self.last_manual,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Quota":
        data = data or {}
        spends = []
        for item in data.get("spends") or []:
            try:
                spends.append((float(item[0]), int(item[1])))
            except (TypeError, ValueError, IndexError):
                continue
        return cls(
            spends=spends,
            blocked_until=float(data.get("blocked_until", 0.0) or 0.0),
            last_manual=float(data.get("last_manual", 0.0) or 0.0),
        )
