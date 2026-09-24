"""
Самопроверка движка (часы, ключи) и WEB Proxy — новые тревоги сторожа.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Обе части читают чужой формат, и у обеих есть способ
соврать молча: принять незнакомое слово за «исправно» и погасить настоящую
тревогу, или принять непонятный ответ за аварию и кричать после каждого
обновления движка. Поэтому у каждой проверки есть обратная сторона.

Ответы движка сняты 24.09.2026 со стенда и с нового сервера (telemt 3.5.7),
оставлены только читаемые поля. Выдуманный формат проверял бы наши же
представления о нём.
"""
import asyncio

import pytest

from config import settings
from telemt.watchdog import monitor, selftest, web
from telemt.watchdog.incidents import WatchState

# --- настоящие ответы ------------------------------------------------------

САМОПРОВЕРКА = {"ok": True, "data": {"enabled": True, "data": {
    "kdf": {"state": "ok", "ewma_errors_per_min": 0.0,
            "threshold_errors_per_min": 0.3, "errors_total": 0},
    "timeskew": {"state": "ok", "max_skew_secs_15m": 1, "samples_15m": 3,
                 "last_skew_secs": 0, "last_source": "proxy_config_date_header"},
    "pid": {"pid": 3063013, "state": "non-one"}, "bnd": None,
}}}


def самопроверка(skew="ok", skew_secs=1, kdf="ok", rate=0.0):
    return {"ok": True, "data": {"enabled": True, "data": {
        "kdf": {"state": kdf, "ewma_errors_per_min": rate,
                "threshold_errors_per_min": 0.3},
        "timeskew": {"state": skew, "max_skew_secs_15m": skew_secs},
    }}}


РЕСУРСЫ = [
    {"resource": "http_connections", "unit": "slots", "used": 1, "available": 1023,
     "limit": 1024, "closed": False},
    {"resource": "http_handlers", "unit": "slots", "used": 0, "available": 512,
     "limit": 512, "closed": False},
]

WEB_РАБОТАЕТ = {"ok": True, "data": {
    "lifecycle": "running", "available": True, "effective_config_enabled": True,
    "ingress": {"configured_listeners": 1, "live_acceptors": 1,
                "accepting_connections": True, "tcp_accept_total": 212,
                "tcp_accept_error_total": 0},
    "capacity": {"resources": РЕСУРСЫ, "saturated_resources": [], "partial": []},
    "operator_lifecycle": {"state": "running", "admission_open": True,
                           "effective_new_work_admission": True},
}}


def web_ответ(accepting=True, reason=None, enabled=True, lifecycle="running",
              resources=None, admission=True, operator_state="running"):
    ingress = {"accepting_connections": accepting}
    if reason:
        ingress["reason"] = reason
    return {"ok": True, "data": {
        "lifecycle": lifecycle, "effective_config_enabled": enabled,
        "ingress": ingress,
        "capacity": {"resources": resources if resources is not None else РЕСУРСЫ,
                     "saturated_resources": []},
        "operator_lifecycle": {"state": operator_state,
                               "effective_new_work_admission": admission},
    }}


# --- разбор самопроверки ---------------------------------------------------

def test_исправный_сервер_исправен():
    в = selftest.read_verdict(САМОПРОВЕРКА)
    assert в.skew_bad is False and в.kdf_bad is False
    assert в.skew_secs == 1


def test_ошибка_часов_видна_с_расхождением():
    в = selftest.read_verdict(самопроверка(skew="error", skew_secs=94))
    assert в.skew_bad is True and в.skew_secs == 94
    assert в.kdf_bad is False, "часы и ключи решаются отдельно"


def test_ошибка_ключей_видна_с_частотой():
    в = selftest.read_verdict(самопроверка(kdf="error", rate=1.25))
    assert в.kdf_bad is True
    assert в.kdf_rate == 1.25 and в.kdf_threshold == 0.3


@pytest.mark.parametrize("ответ", [
    None, "мусор", {}, {"ok": True, "data": None},
    {"ok": True, "data": {"enabled": False, "reason": "source_unavailable", "data": None}},
])
def test_нечитаемое_это_не_знаем(ответ):
    """Пул не поднят или формат чужой — не «исправно» и не «авария»."""
    в = selftest.read_verdict(ответ)
    assert в.skew_bad is None and в.kdf_bad is None


def test_незнакомое_слово_не_гасит_тревогу():
    """Новое слово в новой версии движка — «не знаем», а не «ok»."""
    в = selftest.read_verdict(самопроверка(skew="degraded", kdf="warn"))
    assert в.skew_bad is None and в.kdf_bad is None


# --- разбор WEB ------------------------------------------------------------

def test_работающий_web_принимает_и_не_полон():
    в = web.read_verdict(WEB_РАБОТАЕТ)
    assert в.in_use and в.accepting is True and в.full == []


def test_закрытый_приём_с_причиной():
    в = web.read_verdict(web_ответ(accepting=False, reason="acceptor_unavailable"))
    assert в.accepting is False
    assert "цикл приёма" in в.reason_label()


def test_пауза_из_панели_считается_закрытым_приёмом():
    """Флаг приёма про паузу не знает — её видно только по забору оператора."""
    в = web.read_verdict(web_ответ(accepting=True, admission=False, operator_state="paused"))
    assert в.accepting is False
    assert "приостановлен" in в.reason_label()


def test_незнакомая_причина_показывается_как_есть():
    в = web.read_verdict(web_ответ(accepting=False, reason="new_reason_x"))
    assert в.reason_label() == "new_reason_x"


def test_занятый_целиком_ресурс_виден():
    полный = [dict(РЕСУРСЫ[0], used=1024, available=0), РЕСУРСЫ[1]]
    в = web.read_verdict(web_ответ(resources=полный))
    assert в.full == [("http_connections", 1024, 1024)]
    assert в.full_label() == "http_connections 1024/1024"


def test_почти_полный_ещё_не_полный():
    """Обратная сторона: 1023 из 1024 — ещё не отказ."""
    почти = [dict(РЕСУРСЫ[0], used=1023, available=1), РЕСУРСЫ[1]]
    assert web.read_verdict(web_ответ(resources=почти)).full == []


def test_закрытый_ресурс_не_называется_нехваткой():
    закрытый = [dict(РЕСУРСЫ[0], used=0, limit=0, closed=True)]
    assert web.read_verdict(web_ответ(resources=закрытый)).full == []


@pytest.mark.parametrize("ответ", [
    web_ответ(enabled=False),
    web_ответ(accepting=False, lifecycle="no_web_listener"),
])
def test_сервер_без_web_молчит(ответ):
    """Без WEB «не принимает» — норма, а не авария."""
    assert web.read_verdict(ответ).in_use is False


@pytest.mark.parametrize("ответ", [None, "мусор", {}, {"ok": True, "data": []}])
def test_нечитаемый_web_это_не_знаем(ответ):
    в = web.read_verdict(ответ)
    assert в.in_use is False and в.accepting is None


# --- сквозной прогон через сторожа -----------------------------------------

class ЗаглушкаБота:
    def __init__(self):
        self.sent: list[str] = []

    async def send_message(self, chat_id, text, parse_mode=None):
        self.sent.append(text)


class ЗаглушкаAPI:
    """Отдаёт то, что положили; бросает, если положили исключение."""

    def __init__(self):
        self.selftest = САМОПРОВЕРКА
        self.web = WEB_РАБОТАЕТ

    async def me_selftest(self):
        if isinstance(self.selftest, Exception):
            raise self.selftest
        return self.selftest

    async def web_status(self):
        if isinstance(self.web, Exception):
            raise self.web
        return self.web


@pytest.fixture
def сторож(monkeypatch):
    """Чистое состояние, на диск не пишет: боевой файл сторожа не трогаем."""
    monkeypatch.setattr(monitor, "_save_state", lambda state: None)
    monkeypatch.setattr(settings, "ADMIN_IDS", [1])
    w = monitor.Watchdog()
    w.state = WatchState()
    w.api = ЗаглушкаAPI()
    return w


def опрос(сторож, бот, раз=1):
    async def сценарий():
        for _ in range(раз):
            await сторож._poll_selftest(бот)
            await сторож._poll_web(бот)
    asyncio.run(сценарий())


def test_исправный_сервер_молчит(сторож):
    бот = ЗаглушкаБота()
    опрос(сторож, бот, раз=5)
    assert бот.sent == []


def test_часы_тревога_с_первого_опроса_и_отбой(сторож):
    бот = ЗаглушкаБота()
    сторож.api.selftest = самопроверка(skew="error", skew_secs=94)
    опрос(сторож, бот)
    assert len(бот.sent) == 1 and "ЧАСЫ СЕРВЕРА" in бот.sent[0]
    assert "94" in бот.sent[0] and "timedatectl" in бот.sent[0]
    сторож.api.selftest = САМОПРОВЕРКА
    опрос(сторож, бот)
    assert "СНОВА СОВПАДАЮТ" in бот.sent[-1]


def test_пропавший_ответ_не_снимает_тревогу(сторож):
    """Движок не ответил — это не «часы починились»."""
    бот = ЗаглушкаБота()
    сторож.api.selftest = самопроверка(skew="error", skew_secs=94)
    опрос(сторож, бот)
    сторож.api.selftest = RuntimeError("нет связи")
    опрос(сторож, бот, раз=3)
    assert len(бот.sent) == 1, бот.sent
    assert сторож.state.clock_skew.firing


def test_web_не_принимает_после_трёх_опросов(сторож):
    """Один опрос в starting после перезапуска — не авария."""
    бот = ЗаглушкаБота()
    сторож.api.web = web_ответ(accepting=False, reason="starting")
    опрос(сторож, бот, раз=2)
    assert бот.sent == []
    опрос(сторож, бот)
    assert len(бот.sent) == 1 and "НЕ ПРИНИМАЕТ" in бот.sent[0]
    assert "поднимает" in бот.sent[0]
    сторож.api.web = WEB_РАБОТАЕТ
    опрос(сторож, бот)
    assert "СНОВА ПРИНИМАЕТ" in бот.sent[-1]


def test_web_упёрся_в_предел(сторож):
    бот = ЗаглушкаБота()
    полный = [dict(РЕСУРСЫ[0], used=1024, available=0)]
    сторож.api.web = web_ответ(resources=полный)
    опрос(сторож, бот, раз=3)
    assert len(бот.sent) == 1 and "ПРЕДЕЛ" in бот.sent[0]
    assert "http_connections 1024/1024" in бот.sent[0]
    assert "[web.limits]" in бот.sent[0]


def test_сервер_без_web_не_тревожит_никогда(сторож):
    бот = ЗаглушкаБота()
    сторож.api.web = web_ответ(accepting=False, enabled=False)
    опрос(сторож, бот, раз=10)
    assert бот.sent == []


def test_тревога_видна_в_карточке(сторож):
    бот = ЗаглушкаБота()
    сторож.api.selftest = самопроверка(kdf="error", rate=1.2)
    опрос(сторож, бот)
    assert "ошибки ключей" in сторож.render_status()


def test_исправная_карточка_о_них_молчит(сторож):
    опрос(сторож, ЗаглушкаБота())
    карточка = сторож.render_status()
    for слово in ("часы", "ключей", "WEB"):
        assert слово not in карточка, карточка


def test_новые_тревоги_переживают_перезапуск():
    st = WatchState()
    st.clock_skew.update(True, now=0)
    for t in range(3):
        st.web_down.update(True, now=t)
    назад = WatchState.from_dict(st.to_dict(), 3)
    assert назад.clock_skew.firing and назад.web_down.firing
    assert назад.clock_skew.threshold == 1, "порог часов свой, не общий"


def test_старое_состояние_без_новых_полей_читается():
    st = WatchState.from_dict({"engine": {"bad": 0, "firing": False}}, 3)
    assert not st.clock_skew.firing and not st.web_full.firing
