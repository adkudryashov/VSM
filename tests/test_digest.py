"""
Сводка за сутки (telemt/digest).

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Почти все числа сводки — разница двух снимков
накопительных счётчиков, а счётчики сбрасываются: перезагрузка обнуляет
трафик интерфейса и фаервол, перезапуск движка — трафик пользователей telemt и
счётчик прощупываний, панель 3x-ui сбрасывает трафик клиента кнопкой. Ошибка в
разнице видна только как неправдоподобное число в сообщении — его никто не
сверит. Поэтому сбросы проверяются здесь, на выдуманных числах.

Второе — расписание: 22:00 по Москве на сервере в другом поясе, и пропущенная
рассылка (бот стоял) обязана уйти при старте, а не через сутки.
"""

import sqlite3
import time
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from telemt.digest import ledger as L
from telemt.digest import report as R
from telemt.digest import sources as S
from telemt.watchdog import upgrades

МСК = ZoneInfo("Europe/Moscow")


def мск(*args) -> float:
    return datetime(*args, tzinfo=МСК).timestamp()


# ------------------------------------------------------------ счётчики
def test_прирост_обычный():
    assert R.delta(150, 100) == 50


def test_счётчик_сбросился_считаем_с_нуля():
    assert R.delta(30, 100) == 30


def test_новый_пользователь_весь_счёт():
    assert R.delta(70, None) == 70


def test_по_именам_и_перезапуск_движка():
    prev = {"adkrw": 1000, "family": 500}
    now = {"adkrw": 1500, "family": 800, "smlab": 40}
    assert R.per_name(now, prev) == {"adkrw": 500, "family": 300, "smlab": 40}
    # Движок перезапускался: его счётчики с нуля. Вычитать прежние нельзя —
    # 800 после перезапуска минус 500 до него дало бы 300 вместо 800.
    assert R.per_name(now, prev, restarted=True) == now


# ---------------------------------------------------------- расписание
def test_следующая_рассылка_сегодня():
    assert R.next_run(мск(2026, 9, 26, 10, 0), "22:00", "Europe/Moscow") == мск(2026, 9, 26, 22, 0)


def test_после_22_следующая_завтра():
    assert R.next_run(мск(2026, 9, 26, 22, 0), "22:00", "Europe/Moscow") == мск(2026, 9, 27, 22, 0)


def test_пропущенная_рассылка_уходит_при_старте():
    """Сутки закрыли 25.09 в 22:00, бот стоял 26.09 с 21:50 до 23:10."""
    last = мск(2026, 9, 25, 22, 0)
    assert мск(2026, 9, 26, 23, 10) >= R.next_run(last, "22:00", "Europe/Moscow")


# ------------------------------------------------------------- формат
def test_размеры():
    assert R.size(7_500_000_000) == "7,5 ГБ"
    assert R.size(600_000_000) == "600 МБ"
    assert R.size(0) == "0"


def test_сравнение_со_вчера():
    assert R.change(112, 100) == "↑ 12% ко вчера"
    assert R.change(92, 100) == "↓ 8% ко вчера"
    assert R.change(100, None) == ""
    assert R.change(100, 0) == ""


def test_окно():
    a = мск(2026, 9, 25, 22, 0)
    assert R.window_label(a, a + 86400) == "за сутки"
    assert R.window_label(a, a + 86400 + 70 * 60) == "за 25 ч 10 мин"


@pytest.mark.parametrize("value, hist, итог", [
    (17, [15, 20, 18], ""),
    (212, [15, 20, 18], " ⚠️ ×12"),
    (212, [15, 20], ""),              # истории меньше трёх суток — не с чем сравнить
    (40, [3, 4, 5], ""),              # в разы больше, но меньше полусотни — шум
])
def test_всплеск_прощупываний(value, hist, итог):
    assert R.surge(value, hist) == итог


def test_событие_обрезается_окном():
    a, b = 1000.0, 1000.0 + 86400
    e = {"kind": "dc_dead", "start": a - 3600, "end": a + 600}
    assert R.overlapping([e], a, b) == [e]
    assert R.clipped_minutes(e, a, b) == 10
    незакрытое = {"kind": "engine", "start": b - 1800, "end": None}
    assert R.clipped_minutes(незакрытое, a, b) == 30
    давнее = {"kind": "engine", "start": a - 7200, "end": a - 3600}
    assert R.overlapping([давнее], a, b) == []


def _facts(**kw):
    a = мск(2026, 9, 25, 22, 0)
    base = dict(server="HostUp", a=a, b=a + 86400, traffic=7_500_000_000,
                traffic_prev=6_700_000_000,
                xui={"adkrw": 2_100_000_000, "chekhov": 600_000_000},
                telemt={"adkrw": 300_000_000, "family": 1_200_000_000, "smlab": 0},
                peak=(11, a + 86000), ssh=2339, ssh_prev=2540, bans=(41, 14, 5),
                probes=17, probes_hist=[15, 20, 18], firewall=1922,
                ru=(48, 0), hub_total=5, backup=("ok", 53_000))
    base.update(kw)
    return R.Facts(**base)


def test_спокойный_день():
    t = R.render(_facts())
    assert "HostUp</b> · 26.09 22:00, за сутки" in t
    assert "7,5 ГБ  ↑ 12% ко вчера" in t
    assert "telemt: adkrw 300 МБ · family 1,2 ГБ · smlab 0" in t
    assert "2 339 попыток подбора · ↓ 8% ко вчера" in t
    assert "до суток и дольше: 5" in t
    assert "Сторож: тревог нет" in t and "все DC на связи" in t
    assert "Серверы: все 5 на связи" in t and "Копия: сделана · 52 КБ" in t
    assert "✅ Обслуживание не требуется" in t
    assert "⚠️" not in t


def test_день_с_событиями():
    a = мск(2026, 9, 25, 22, 0)
    evs = [{"kind": "dc_dead", "start": a + 3600, "end": a + 3600 + 130 * 60, "detail": "5"},
           {"kind": "beszel_silent", "start": a + 7200, "end": a + 7200 + 720, "detail": "VEESP"}]
    t = R.render(_facts(events=evs, ru=(48, 1), backup=("missing", True),
                        maint=["⚠️ Нужна перезагрузка (ядро)"]))
    assert "Сторож: ⚠️ 2 тревоги · 2 ч 22 мин" in t
    assert "Telegram: ⚠️ DC 5 пропадал 2 ч 10 мин" in t
    assert "Серверы: ⚠️ VEESP недоступен 12 мин" in t
    assert "Россия: ⚠️ недоступен 1 из 48" in t
    assert "Копия: ⚠️ не сделана — ошибка" in t
    assert "🔧 <b>Обслуживание</b>" in t and "Нужна перезагрузка (ядро)" in t


def test_перезагрузка_посреди_суток_без_сравнения():
    t = R.render(_facts(traffic_since_boot=True))
    assert "≈ 7,5 ГБ" in t and "ко вчера" not in t.split("\n")[2]
    assert "счёт с загрузки" in t


def test_имена_экранируются():
    t = R.render(_facts(telemt={"<b>x</b>": 1}))
    assert "&lt;b&gt;x&lt;/b&gt;" in t


def test_без_хаба_и_fail2ban():
    t = R.render(_facts(hub_total=None, bans=None))
    assert "Серверы" not in t
    assert "fail2ban не установлен" in t


# -------------------------------------------------------------- состояние
def test_события_и_сутки(tmp_path, monkeypatch):
    led = L.Ledger(tmp_path / "digest.json")
    led.record("dc_dead", "fire", 1000.0, "5", now=1100.0)
    led.record("dc_dead", "clear", None, now=2000.0)
    assert led.data["events"] == [{"kind": "dc_dead", "start": 1000.0, "end": 2000.0, "detail": "5"}]
    assert led.note_peak(7, now=1500.0) and not led.note_peak(5, now=1600.0)
    led.roll(3000.0, {"nic": 1}, traffic=10, ssh=20, probes=30)
    again = L.Ledger(tmp_path / "digest.json")          # пережило перезапуск
    assert again.data["prev"] == {"traffic": 10, "ssh": 20}
    assert again.data["probes_hist"] == [30] and again.data["peak"] == {}


def test_старые_события_забываются(tmp_path):
    led = L.Ledger(tmp_path / "digest.json")
    led.data["events"] = [{"kind": "engine", "start": 0.0, "end": 10.0, "detail": ""}]
    led.record("engine", "fire", 20 * 86400.0, now=20 * 86400.0)
    assert [e["start"] for e in led.data["events"]] == [20 * 86400.0]


def test_выключатель_важнее_настройки(tmp_path, monkeypatch):
    from config import settings
    monkeypatch.setattr(settings, "DIGEST_ENABLED", False)
    led = L.Ledger(tmp_path / "digest.json")
    assert led.enabled is False
    led.set_enabled(True)
    assert L.Ledger(tmp_path / "digest.json").enabled is True


def test_имя_позиции_сторожа():
    from telemt.watchdog.incidents import WatchState
    st = WatchState.from_dict({}, 3)
    assert L.flap_name(st, st.dc_dead) == "dc_dead"
    assert L.flap_name(st, st.beszel_silent) == "beszel_silent"


# ------------------------------------------------------------- источники
def test_проверки_из_россии(tmp_path, monkeypatch):
    p = tmp_path / "history.jsonl"
    p.write_text(
        '{"checked_at":"2026-09-25T17:59:35Z","percentage":100}\n'
        '{"checked_at":"2026-09-25T18:14:13Z","percentage":20}\n'
        'мусор\n'
        '{"checked_at":"2026-09-20T10:00:00Z","percentage":100}\n', encoding="utf-8")
    monkeypatch.setattr(S, "RU_HISTORY", str(p))
    a = datetime(2026, 9, 25, 0, 0, tzinfo=ZoneInfo("UTC")).timestamp()
    assert S.ru_checks(a, a + 86400) == (2, 1)


def test_баны_и_ступени(tmp_path, monkeypatch):
    db = tmp_path / "f2b.sqlite3"
    con = sqlite3.connect(db)
    con.execute("create table bans(jail text, ip text, timeofban integer, bantime integer, "
                "bancount integer, data json)")
    rows = [("sshd", "1.1.1.1", 100, 900), ("sshd", "1.1.1.1", 200, 3600),
            ("sshd", "1.1.1.1", 300, 86400), ("sshd", "2.2.2.2", 150, 900),
            ("3x-ipl", "3.3.3.3", 150, 900), ("sshd", "4.4.4.4", 99999, 900)]
    con.executemany("insert into bans values (?,?,?,?,1,'{}')", rows)
    con.commit()
    con.close()
    monkeypatch.setattr(S, "F2B_DB", str(db))
    monkeypatch.setattr(S.shutil, "which", lambda _: "/usr/bin/fail2ban-client")
    assert S.bans(0, 1000) == (4, 2, 1)


def test_пакеты_автообновления_за_окно(tmp_path):
    p = tmp_path / "history.log"
    p.write_text("Start-Date: 2026-09-26  06:04:10\n"
                 "Commandline: /usr/bin/unattended-upgrade\n"
                 "Upgrade: openssl:amd64 (3.5.5-1, 3.5.5-2), libssl3t64:amd64 (3.5.5-1, 3.5.5-2)\n"
                 "End-Date: 2026-09-26  06:05:00\n\n"
                 "Start-Date: 2026-09-26  07:00:00\n"
                 "Commandline: apt install htop\n"
                 "Install: htop:amd64 (3.4.1-1)\n"
                 "End-Date: 2026-09-26  07:00:03\n", encoding="utf-8")
    a = datetime(2026, 9, 25, 22, 0).timestamp()
    assert upgrades.packages_between(a, a + 86400, p) == ["openssl", "libssl3t64"]


def test_лимиты_молчат_без_лимитов():
    now = time.time()
    assert S.limits([("adkrw", 5 * 10**9, 0, 0)],
                    [{"username": "family", "total_octets": 10**9, "data_quota_bytes": 0}], now) == []


def test_лимиты_на_исходе():
    now = time.time()
    out = S.limits([("adkrw", 95, 100, int((now + 3 * 86400 + 60) * 1000))],
                   [{"username": "smlab", "total_octets": 0,
                     "expiration_rfc3339": datetime.fromtimestamp(now + 2 * 86400 + 60, ZoneInfo("UTC")).isoformat()}],
                   now)
    assert any("adkrw: израсходовано 95%" in s for s in out)
    assert any("adkrw: срок через 3 дн." in s for s in out)
    assert any("smlab: срок через 2 дн." in s for s in out)
