"""
Пустая группа дата-центров Telegram.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Сигнал появился из живой аварии: 08.09.2026 группы DC 5
и -5 стояли без единого писателя сутки, а сторож молчал — общее покрытие было
77% при пороге 50, и по нему всё выглядело исправным. Среднее и не должно было
просесть: две пустые группы из двенадцати его почти не двигают.

Проверяется не только срабатывание, но и обратное — иначе сигнал, который
кричит всегда, выключат вместе с настоящими тревогами. Контрольные случаи:
исправный сервер молчит, полностью мёртвый пул тоже молчит (это чужая тревога),
а нечитаемый ответ даёт «не знаю», а не аварию.

Ответ движка подсмотрен на стенде, а не выдуман: выдуманный формат проверял бы
наши же представления о нём.
"""

from telemt.watchdog import dcs

# Настоящий ответ /v1/stats/dcs со стенда 08.09.2026, в разгар аварии.
# Оставлены только читаемые нами поля.
АВАРИЯ = {"data": {"dcs": [
    {"dc": -203, "alive_writers": 4, "required_writers": 3, "coverage_pct": 100.0},
    {"dc": -5,   "alive_writers": 0, "required_writers": 3, "coverage_pct": 0.0},
    {"dc": -4,   "alive_writers": 2, "required_writers": 3, "coverage_pct": 66.7},
    {"dc": -3,   "alive_writers": 5, "required_writers": 3, "coverage_pct": 100.0},
    {"dc": -2,   "alive_writers": 3, "required_writers": 3, "coverage_pct": 100.0},
    {"dc": -1,   "alive_writers": 4, "required_writers": 3, "coverage_pct": 100.0},
    {"dc": 1,    "alive_writers": 3, "required_writers": 3, "coverage_pct": 100.0},
    {"dc": 2,    "alive_writers": 3, "required_writers": 3, "coverage_pct": 100.0},
    {"dc": 3,    "alive_writers": 3, "required_writers": 3, "coverage_pct": 100.0},
    {"dc": 4,    "alive_writers": 2, "required_writers": 10, "coverage_pct": 20.0},
    {"dc": 5,    "alive_writers": 0, "required_writers": 3, "coverage_pct": 0.0},
    {"dc": 203,  "alive_writers": 4, "required_writers": 3, "coverage_pct": 100.0},
]}}


def _группы(*пары):
    """Ответ движка из пар «номер группы, живых писателей»."""
    return {"data": {"dcs": [
        {"dc": dc, "alive_writers": alive, "required_writers": 3}
        for dc, alive in пары
    ]}}


def test_живая_авария_видна_поимённо():
    в = dcs.read_verdict(АВАРИЯ)
    assert в.total == 12
    assert в.dead == [-5, 5]
    assert в.partial
    assert в.label() == "-5, 5"


def test_просевшая_но_живая_группа_не_считается_пустой():
    # DC 4 в той же аварии: покрытие 20%, но писатели есть. Это забота
    # общего порога покрытия, а не наша: здесь мы про ноль, а не про «мало».
    в = dcs.read_verdict(АВАРИЯ)
    assert 4 not in в.dead
    assert -4 not in в.dead


def test_исправный_сервер_молчит():
    в = dcs.read_verdict(_группы((1, 3), (2, 3), (-1, 4)))
    assert в.total == 3
    assert в.dead == []
    assert not в.partial


def test_полностью_мёртвый_пул_не_наша_тревога():
    # Все группы пусты — это «движок ещё не поднял пул» либо «связи нет
    # совсем». Первое штатно после каждого перезапуска, второе уже покрыто
    # тревогами по движку и по покрытию. Три сообщения об одном событии —
    # это шум, за которым перестают следить.
    в = dcs.read_verdict(_группы((1, 0), (2, 0), (-1, 0)))
    assert в.total == 3
    assert len(в.dead) == 3
    assert not в.partial


def test_группе_без_нужды_в_писателях_ноль_не_страшен():
    ответ = {"data": {"dcs": [
        {"dc": 1, "alive_writers": 3, "required_writers": 3},
        {"dc": 9, "alive_writers": 0, "required_writers": 0},
    ]}}
    в = dcs.read_verdict(ответ)
    assert в.total == 1
    assert в.dead == []


def test_порядок_вывода_устойчив():
    # Сообщение владельцу должно читаться одинаково от опроса к опросу,
    # иначе повтор тревоги выглядит как новая авария.
    прямой = dcs.read_verdict(_группы((5, 0), (-5, 0), (2, 0), (1, 3)))
    обратный = dcs.read_verdict(_группы((1, 3), (2, 0), (-5, 0), (5, 0)))
    assert прямой.dead == обратный.dead == [2, -5, 5]


def test_нечитаемое_это_отсутствие_данных():
    # Формат чужой. Сторож, принимающий непонятный ответ за аварию, поднимет
    # ложную тревогу ровно в день обновления движка.
    for мусор in (None, [], "строка", 42, {}, {"data": {}},
                  {"data": {"dcs": "не список"}}, {"data": {"dcs": None}}):
        в = dcs.read_verdict(мусор)
        assert в.total == 0, мусор
        assert в.dead == []
        assert not в.partial


def test_испорченные_записи_пропускаются_молча():
    ответ = {"data": {"dcs": [
        {"dc": 1, "alive_writers": 3, "required_writers": 3},
        {"dc": 2},                                    # нет писателей вовсе
        {"alive_writers": 0, "required_writers": 3},  # нет номера группы
        {"dc": 3, "alive_writers": "ноль"},           # не число
        "вообще не запись",
        {"dc": 4, "alive_writers": 0, "required_writers": 3},
    ]}}
    в = dcs.read_verdict(ответ)
    assert в.total == 2
    assert в.dead == [4]


def test_ответ_без_обёртки_data_тоже_читается():
    # /v1/stats/dcs отдаёт {"ok":..., "data":{...}}, но клиент местами
    # разворачивает data сам. Читаем оба вида, чтобы правка вызова не
    # выключила тревогу молча.
    прямо = {"dcs": [{"dc": 1, "alive_writers": 0, "required_writers": 3},
                     {"dc": 2, "alive_writers": 3, "required_writers": 3}]}
    в = dcs.read_verdict(прямо)
    assert в.total == 2
    assert в.dead == [1]
    assert в.partial
