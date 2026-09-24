"""
WEB Proxy: принимает ли он соединения и не упёрся ли в свои пределы.

ЗАЧЕМ. WEB — самая молодая и самая хрупкая часть стека. 23.09.2026 чужой
установщик telemt переписал все строки «port =» подряд, и WEB-слушатель сел
на порт основного прокси: движок не поднялся вовсе, но сторож назвал бы это
только «движок недоступен». Тоньше случай, когда движок жив, а WEB — нет:
слушатель не поднялся, приём приостановлен из панели, приём закончился. За
WEB до сих пор следил только реестр, и только за блоком в nginx.

ДВЕ ТРЕВОГИ, А НЕ ОДНА.

  Не принимает. Движок сам отвечает на этот вопрос одним флагом
  (ingress.accepting_connections) и называет причину. Флаг учитывает всё
  сразу: состояние жизненного цикла, живой цикл приёма на каждом слушателе,
  приостановку оператором. Своих правил поверх не строим.

  Упёрся в предел. Приём открыт, но какой-то из фиксированных ресурсов
  (соединения, обработчики, байты очередей) занят целиком. Клиенты при этом
  получают отказ по одному, а общий флаг остаётся зелёным — отдельный
  сигнал нужен именно поэтому.

ГИСТЕРЕЗИС ОБЫЧНЫЙ, ТРИ ОПРОСА. После каждого перезапуска движка WEB
несколько секунд в состоянии starting, а заполненность ресурса — мгновенный
снимок, и одиночный всплеск это не авария.

WEB НЕ ВКЛЮЧЁН — МОЛЧИМ. На сервере без WEB-слушателя «не принимает» — это
норма, а не авария. Как и в dcs.py, нечитаемый ответ — отсутствие данных:
тревогу не поднимаем и висящую не снимаем.

ГРАНИЦА. Движок не отвечает за nginx перед собой: отказ на стороне nginx или
не дошедшее до accept(2) соединение отсюда не видны. Это остаётся за
позицией реестра web_nginx_block.
"""

from dataclasses import dataclass, field
from typing import Optional

# Слушатель не настроен вовсе — WEB на этом сервере не используют.
NOT_CONFIGURED = "no_web_listener"

# Причины, которыми движок объясняет закрытый приём. Незнакомую причину
# показываем как есть: движок новее бота — это нормально.
REASONS = {
    "starting": "движок ещё поднимает WEB",
    "ingress_draining": "приём сворачивается — запущено осушение",
    "ingress_drained": "приём свёрнут — осушение закончено",
    "deadline_exceeded": "осушение упёрлось в срок",
    "runtime_released": "среда WEB освобождена",
    "acceptor_unavailable": "цикл приёма соединений не работает",
    "paused": "приём приостановлен оператором — например, из панели",
}


@dataclass
class WebVerdict:
    """Что известно о WEB по одному ответу /v1/runtime/web/status."""

    # WEB включён в действующем конфиге движка. Ложь — молчим обо всём.
    in_use: bool = False
    # None — не знаем.
    accepting: Optional[bool] = None
    reason: str = ""
    # Занятые целиком ресурсы: (имя, занято, предел).
    full: list = field(default_factory=list)

    def reason_label(self) -> str:
        return REASONS.get(self.reason, self.reason or "причину движок не назвал")

    def full_label(self) -> str:
        return ", ".join(f"{name} {used}/{limit}" for name, used, limit in self.full)


def _int(value) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value)


def _full_resources(capacity) -> list:
    """
    Ресурсы, занятые целиком.

    Смотрим на числа, а не только на saturated_resources: форма этого списка в
    документации не описана, а у нас на обоих серверах он пуст — угадывать его
    устройство по пустому месту нельзя. Имена оттуда берём, только если это
    строки или словари с полем resource, и добавляем, не дублируя.
    """
    if not isinstance(capacity, dict):
        return []
    out = []
    seen = set()
    for res in capacity.get("resources") or []:
        if not isinstance(res, dict):
            continue
        name = res.get("resource")
        used, limit = _int(res.get("used")), _int(res.get("limit"))
        # Закрытый ресурс — это сворачивание, а не нехватка: о нём скажет
        # флаг приёма, дважды одно событие не называем.
        if not isinstance(name, str) or res.get("closed") is True:
            continue
        if used is not None and limit and used >= limit:
            out.append((name, used, limit))
            seen.add(name)
    for item in capacity.get("saturated_resources") or []:
        name = item if isinstance(item, str) else (
            item.get("resource") if isinstance(item, dict) else None)
        if isinstance(name, str) and name not in seen:
            out.append((name, "?", "?"))
            seen.add(name)
    return out


def read_verdict(payload) -> WebVerdict:
    """Разбирает ответ движка — полный конверт {"ok", "data"} или его середину."""
    if not isinstance(payload, dict):
        return WebVerdict()
    data = payload.get("data") if "ok" in payload else payload
    if not isinstance(data, dict):
        return WebVerdict()

    lifecycle = data.get("lifecycle")
    if data.get("effective_config_enabled") is not True or lifecycle == NOT_CONFIGURED:
        return WebVerdict()

    ingress = data.get("ingress")
    accepting = None
    reason = ""
    if isinstance(ingress, dict) and isinstance(ingress.get("accepting_connections"), bool):
        accepting = ingress["accepting_connections"]
        reason = str(ingress.get("reason") or "")
    # Приостановка оператором — отдельный забор. По документации API флаг
    # приёма складывается из жизненного цикла и живых циклов accept(2), про
    # приостановку там ни слова: соединение принимается, а новая работа — нет.
    # Смотрим на неё сами, иначе пауза из панели прошла бы мимо сторожа, а
    # причина тут самая полезная: её поставил человек, и снимается она кнопкой.
    operator = data.get("operator_lifecycle")
    if isinstance(operator, dict) and operator.get("effective_new_work_admission") is False:
        accepting = False
        reason = reason or str(operator.get("state") or "")
    if accepting is False and not reason:
        reason = str(lifecycle or "")

    return WebVerdict(in_use=True, accepting=accepting, reason=reason,
                      full=_full_resources(data.get("capacity")))
