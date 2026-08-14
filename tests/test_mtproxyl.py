"""
Чтение чужого вердикта доступности (MTProxyL).

ЗАЧЕМ ЭТО ПОКРЫВАТЬ ПЛОТНЕЕ ВСЕГО. Модуль разбирает файл, формат которого
задаём не мы: `/opt/mtproxyl/availability/last.json` пишет чужая программа,
обновляемая независимо от VSM. У него ровно один контракт, и он записан в
самом модуле: всё, что не удалось прочитать или разобрать, считается «данных
нет», а не поводом для тревоги. Ложная тревога о падении доступности из-за
того, что автор переименовал поле, — худший исход из возможных.

Поэтому здесь проверяется не «разбирает правильный файл» (это одна строка), а
десяток способов, которыми чужой файл может испортиться, и на каждом ожидается
None. Проверка, умеющая только подтверждать удачный разбор, этот контракт не
защищает вовсе.
"""
import json
from datetime import datetime, timezone

import pytest

from telemt.watchdog import mtproxyl

# --- Как выглядит исправный вердикт ---------------------------------------

GOOD = {
    "checked_at": "2026-08-14T12:00:00Z",
    "target": "1.2.3.4:443",
    "total_probes": 4,
    "success_probes": 3,
    "percentage": 75.0,
    "probes": [
        {"tls_success": True, "city": "Москва", "network": "Ростелеком", "asn": 12389},
        {"tls_success": True, "city": "Казань", "network": "МТС", "asn": 8359},
        {"tls_success": True, "city": "Пермь", "network": "ЭР-Телеком", "asn": 31200},
        {"tls_success": False, "city": "Омск", "network": "Билайн", "asn": 3216,
         "error": "handshake timeout"},
    ],
}


def test_разбирает_исправный_вердикт(verdict_file):
    got = mtproxyl.read_verdict(verdict_file(json.dumps(GOOD)))
    assert got["success"] == 3
    assert got["total"] == 4
    assert got["pct"] == 75.0
    assert got["source"] == "mtproxyl"
    # Зонды приводятся к тому же виду, что отдаёт наш собственный замер, —
    # разбор по зондам показывается одним кодом независимо от того, кто мерил.
    assert len(got["probes"]) == 4
    assert got["probes"][0]["ok"] is True
    assert got["probes"][0]["city"] == "Москва"


def test_причина_отказа_попадает_в_сводку(verdict_file):
    got = mtproxyl.read_verdict(verdict_file(json.dumps(GOOD)))
    assert got["reasons"] == {"handshake timeout": 1}
    assert got["probes"][3]["error"] == "handshake timeout"


def test_зонд_без_причины_получает_осмысленную(verdict_file):
    """Пустое error у неудачного зонда — не повод показать пустую строку."""
    data = json.loads(json.dumps(GOOD))
    data["probes"][3]["error"] = ""
    got = mtproxyl.read_verdict(verdict_file(json.dumps(data)))
    assert got["probes"][3]["error"] == "соединение не установлено"


def test_зонды_свои_кредиты_не_тратят(verdict_file):
    """Мерил MTProxyL по своей квоте — нашему реестру трат списывать нечего."""
    got = mtproxyl.read_verdict(verdict_file(json.dumps(GOOD)))
    assert got["charged"] == 0


# --- Контракт: испорченный источник НИКОГДА не превращается в тревогу ------

@pytest.mark.parametrize("содержимое,почему", [
    ("", "пустой файл"),
    ("не json вовсе", "мусор вместо JSON"),
    ("[1, 2, 3]", "список вместо объекта"),
    ('"строка"', "строка вместо объекта"),
    ("null", "null вместо объекта"),
    ('{"total_probes": "много", "success_probes": 1, "percentage": 50}', "нечисловое число"),
    ('{"total_probes": 0, "success_probes": 0, "percentage": 0}', "ни один зонд не взялся"),
    ('{"success_probes": 1, "percentage": 50}', "нет поля total_probes"),
    ('{"total_probes": null, "success_probes": null, "percentage": null}', "поля есть, но пустые"),
])
def test_испорченный_вердикт_это_данных_нет(verdict_file, содержимое, почему):
    """
    Во всех этих случаях судить о доступности нечего, и состояние тревоги
    трогать нельзя. None — единственный допустимый ответ.
    """
    assert mtproxyl.read_verdict(verdict_file(содержимое)) is None, почему


def test_отсутствующий_файл_это_данных_нет(tmp_path):
    assert mtproxyl.read_verdict(str(tmp_path / "нет-такого.json")) is None


def test_ноль_процентов_это_НЕ_данных_нет(verdict_file):
    """
    Обратная сторона контракта, без которой он бессмысленен: честно
    измеренный полный отказ обязан дойти до тревоги, а не утонуть в None.
    """
    data = json.loads(json.dumps(GOOD))
    data["success_probes"] = 0
    data["percentage"] = 0.0
    for probe in data["probes"]:
        probe["tls_success"] = False
    got = mtproxyl.read_verdict(verdict_file(json.dumps(data)))
    assert got is not None
    assert got["pct"] == 0.0
    assert got["success"] == 0


def test_чужая_ошибка_измерения_не_ноль_процентов(verdict_file):
    """
    Непустое error на верхнем уровне означает, что измерения НЕ БЫЛО:
    MTProxyL пишет туда причину, по которой не смог проверить. Считать это
    нулём процентов значило бы поднять тревогу на ровном месте.
    """
    got = mtproxyl.read_verdict(verdict_file(json.dumps(
        {"error": "нет доступа к API", "checked_at": "2026-08-14T12:00:00Z"})))
    assert got is not None
    assert got["error"] == "нет доступа к API"
    assert "pct" not in got


def test_мусор_среди_зондов_пропускается_а_не_роняет(verdict_file):
    """Один кривой элемент списка не должен стоить нам всего вердикта."""
    data = json.loads(json.dumps(GOOD))
    data["probes"] = [data["probes"][0], "строка вместо объекта", None, data["probes"][3]]
    got = mtproxyl.read_verdict(verdict_file(json.dumps(data)))
    assert got is not None
    assert len(got["probes"]) == 2


# --- Отметка времени ------------------------------------------------------

@pytest.mark.parametrize("значение", [
    "2026-08-14T12:00:00Z",
    "2026-08-14T12:00:00+00:00",
    "2026-08-14T12:00:00",          # без зоны — считаем UTC
])
def test_три_записи_одного_момента_дают_одно_время(значение):
    """
    Ожидаемое считается независимым путём, а НЕ вписывается числом.
    Вписанное руками число здесь уже один раз разошлось с правдой ровно на
    сутки, и виноват был тест, а не код: проверка, чьё ожидание получено той же
    головой, что и сомнение, ничего не доказывает.
    """
    ожидаемое = datetime(2026, 8, 14, 12, 0, 0, tzinfo=timezone.utc).timestamp()
    assert mtproxyl._epoch(значение) == ожидаемое


@pytest.mark.parametrize("значение", ["", "позавчера", "2026-13-45T99:99:99Z", "   "])
def test_неразборчивое_время_это_ноль(значение):
    """
    Ноль, а не исключение: по метке checked_at сторож понимает, протух ли
    вердикт, и падать на ней из-за смены формата у автора нельзя.
    """
    assert mtproxyl._epoch(значение) == 0.0


def test_available_отвечает_на_чтение_а_не_на_установку(tmp_path):
    """
    Вопрос именно «можем ли мы прочитать», а не «установлен ли MTProxyL»:
    бот может работать не от root.
    """
    assert mtproxyl.available(str(tmp_path / "нет-такого")) is False
    существующий = tmp_path / "есть.json"
    существующий.write_text("{}", encoding="utf-8")
    assert mtproxyl.available(str(существующий)) is True
