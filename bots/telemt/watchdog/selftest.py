"""
Самопроверка движка: часы сервера и согласование ключей с Telegram.

ЗАЧЕМ. Обе поломки снаружи выглядят как блокировка, а причина у них на самом
сервере — и ни одна прежняя проверка сторожа их не видит.

  Часы. Движок сверяет своё время с заголовком Date в ответах серверов
  Telegram. Разойдутся часы больше чем на минуту — рукопожатия начнут
  отваливаться у всех клиентов разом, при живом движке и полном покрытии
  писателей. Владелец в этот момент ищет блокировку, а чинить надо NTP.

  Ключи (KDF). Для рукопожатия с серверами Telegram движок подмешивает в
  вывод ключей адрес, под которым сервер виден снаружи. Если этот адрес
  скачет между подключениями к одному и тому же серверу Telegram (NAT,
  несколько адресов, неустойчивый ответ STUN), движок считает это ошибкой.
  Проверено по исходникам telemt 3.5.7: src/transport/middle_proxy/handshake.rs,
  счётчик kdf_drift.

ПОРОГОВ СВОИХ НЕТ. Движок сам решает «ok» или «error» и сам сглаживает:
часы — наибольшее расхождение за 15 минут против 60 секунд, ключи —
скользящее среднее с постоянной 10 минут против 0,3 ошибки в минуту
(src/api/runtime_selftest.rs). Второй порог поверх его собственного был бы
лишней ручкой, которая однажды разойдётся с первым. Поэтому и счёт опросов
у этих тревог один, а не три: условие уже сглажено временем.

НЕЧИТАЕМОЕ — ЭТО ОТСУТСТВИЕ ДАННЫХ. Как и в dcs.py: непонятный ответ не
поднимает тревогу и не снимает висящую. Незнакомое значение state тоже
считается «не знаем», а не «исправно»: иначе новая версия движка с новым
словом молча погасила бы настоящую тревогу.
"""

from dataclasses import dataclass
from typing import Optional

OK = "ok"
ERROR = "error"


@dataclass
class SelftestVerdict:
    """Что известно по одному ответу /v1/runtime/me-selftest."""

    # None — не знаем: ответа нет, самопроверка выключена или слово незнакомое.
    skew_bad: Optional[bool] = None
    skew_secs: Optional[int] = None
    kdf_bad: Optional[bool] = None
    kdf_rate: Optional[float] = None
    kdf_threshold: Optional[float] = None


def _state(block) -> Optional[bool]:
    """«error» — плохо, «ok» — хорошо, всё остальное — не знаем."""
    if not isinstance(block, dict):
        return None
    value = block.get("state")
    if value == ERROR:
        return True
    if value == OK:
        return False
    return None


def _number(value) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def read_verdict(payload) -> SelftestVerdict:
    """
    Разбирает ответ движка. Принимает и полный конверт {"ok", "data"}, и его
    содержимое: клиент API отдаёт конверт, проверки удобнее кормить серединой.
    """
    if not isinstance(payload, dict):
        return SelftestVerdict()
    body = payload.get("data") if "ok" in payload else payload
    if not isinstance(body, dict):
        return SelftestVerdict()
    # Самопроверка живёт в пуле писателей. Пул не поднят — enabled=false,
    # и это не «часы исправны», а «сейчас не знаем».
    if body.get("enabled") is False:
        return SelftestVerdict()
    inner = body.get("data") if "enabled" in body else body
    if not isinstance(inner, dict):
        return SelftestVerdict()

    skew = inner.get("timeskew")
    kdf = inner.get("kdf")
    skew_secs = _number((skew or {}).get("max_skew_secs_15m")) if isinstance(skew, dict) else None
    return SelftestVerdict(
        skew_bad=_state(skew),
        skew_secs=None if skew_secs is None else int(skew_secs),
        kdf_bad=_state(kdf),
        kdf_rate=_number((kdf or {}).get("ewma_errors_per_min")) if isinstance(kdf, dict) else None,
        kdf_threshold=_number((kdf or {}).get("threshold_errors_per_min")) if isinstance(kdf, dict) else None,
    )
