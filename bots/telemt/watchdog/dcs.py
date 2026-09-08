"""
Дата-центры Telegram без единого писателя.

ЗАЧЕМ ОТДЕЛЬНЫЙ СИГНАЛ, если покрытие писателей уже под наблюдением.

Покрытие — одно число на весь сервер, и оно усредняет. Замер 08.09.2026 на
нашем стенде: общее покрытие 77% при пороге 50, тревоги нет — а за этими 77%
пусты ЦЕЛИКОМ две группы (DC 5 и -5), доступно 10 точек подключения из 24.
Клиент, чья учётная запись живёт в этом дата-центре, не обслуживается вовсе,
и сторож при этом говорит, что всё хорошо. Так продолжалось сутки.

Этим закрывается вопрос, записанный в upstreams.py: за три минуты полного
отсутствия связи с Telegram ни одна тревога не поднялась, потому что среднее
осталось выше порога. Среднее и не должно было просесть — оно на то и среднее.

ПОЧЕМУ НЕ ПОДНИМАЕМ ТРЕВОГУ, КОГДА ПУСТЫ ВСЕ ГРУППЫ. Это не «один дата-центр
отвалился», а «движок ещё не поднял пул» либо «связи с Telegram нет совсем».
Первое штатно случается несколько секунд после каждого перезапуска, второе уже
покрыто тревогами по движку и по покрытию. Дублировать их значит присылать три
сообщения об одном событии. Поэтому сигнал ровно про частичную потерю.

ПОЧЕМУ НЕ СМОТРИМ НА coverage_pct ГРУППЫ. Ноль писателей — это ноль, здесь
нечего округлять и не с чем сравнивать. Порог тут был бы лишней ручкой, за
которую однажды дёрнут не в ту сторону.

НЕЧИТАЕМОЕ — ЭТО ОТСУТСТВИЕ ДАННЫХ, А НЕ АВАРИЯ. Чужой формат мог поменяться,
и сторож, принимающий непонятный ответ за поломку, поднимет ложную тревогу
ровно тогда, когда обновится движок. Разбор возвращает «групп не видно», а на
таком ответе тревога не поднимается.
"""

from dataclasses import dataclass, field


@dataclass
class DcVerdict:
    """Что известно о группах дата-центров по одному ответу движка."""

    total: int = 0
    dead: list = field(default_factory=list)

    @property
    def partial(self) -> bool:
        """Часть групп пуста, но не все — только это и есть наш случай."""
        return 0 < len(self.dead) < self.total

    def label(self) -> str:
        """Список пустых групп для сообщения: 5, -5."""
        return ", ".join(str(d) for d in self.dead)


def _as_int(value):
    """Число или None. Строку движок вернуть не должен, но чужой формат — чужой."""
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def read_verdict(payload) -> DcVerdict:
    """
    Разбирает ответ /v1/stats/dcs.

    Группа считается пустой, когда живых писателей ровно ноль, а по замыслу
    их требуется хотя бы один: required_writers отделяет настоящую пропажу от
    группы, которой писатели и не положены.
    """
    if not isinstance(payload, dict):
        return DcVerdict()
    data = payload.get("data")
    if not isinstance(data, dict):
        data = payload
    groups = data.get("dcs")
    if not isinstance(groups, list):
        return DcVerdict()

    total = 0
    dead = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        dc = _as_int(group.get("dc"))
        alive = _as_int(group.get("alive_writers"))
        need = _as_int(group.get("required_writers"))
        if dc is None or alive is None:
            continue
        if need is not None and need <= 0:
            continue
        total += 1
        if alive == 0:
            dead.append(dc)

    dead.sort(key=lambda d: (abs(d), d))
    return DcVerdict(total=total, dead=dead)
