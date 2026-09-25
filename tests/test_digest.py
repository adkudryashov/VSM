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
    prev = {"alice": 1000, "carol": 500}
    now = {"alice": 1500, "carol": 800, "dave": 40}
    assert R.per_name(now, prev) == {"alice": 500, "carol": 300, "dave": 40}
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
    D = 86400
    assert R.change(112, 100, D, D) == "↑ 12% ко вчера"
    assert R.change(92, 100, D, D) == "↓ 8% ко вчера"
    assert R.change(100, None, D, D) == ""
    assert R.change(100, 0, D, D) == ""


def test_сравнение_по_скорости_а_не_по_сумме():
    """22:22 25.09: 21 минуту сравнили с 17 и получили «↑ 267%»."""
    D = 86400
    # Полсуток с той же скоростью, что вчера, — это «как вчера», а не «−50%».
    assert R.change(50, 100, D / 2, D) == "как вчера"
    # Отрезок короче трёх часов — не сравниваем вовсе.
    assert R.change(11, 3, 21 * 60, 17 * 60) == ""
    assert R.change(100, 100, 2 * 3600, D) == ""
    # Длина прошлого окна неизвестна (состояние прежней версии) — молчим.
    assert R.change(100, 90, D, None) == ""


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
    base = dict(server="server1", a=a, b=a + 86400, traffic=7_500_000_000,
                traffic_prev=6_700_000_000, prev_span=86400,
                xui={"alice": 2_100_000_000, "bob": 600_000_000},
                telemt={"alice": 300_000_000, "carol": 1_200_000_000, "dave": 0},
                peak=(11, a + 86000), ssh=2339, ssh_prev=2540, bans=(41, 14, 5),
                probes=17, probes_hist=[15, 20, 18], firewall=1922,
                ru=(48, 0), hub_total=5, backup=("ok", 53_000))
    base.update(kw)
    return R.Facts(**base)


def test_спокойный_день():
    t = R.render(_facts())
    assert "server1</b> · 26.09 22:00 · за сутки" in t
    assert "7,5 ГБ  ↑ 12% ко вчера" in t
    assert "alice: 3x-ui 2,1 ГБ · telemt 300 МБ" in t
    assert "bob: 3x-ui 600 МБ" in t and "dave: telemt 0" in t
    assert "Попытки подбора SSH: 2 339 · ↓ 8% ко вчера" in t
    assert "Баны: 41 · 14 адресов" in t and "Баны на сутки и дольше: 5" in t
    assert "🟢 Сторож: тревог нет" in t and "🟢 Telegram: все DC на связи" in t
    assert "🟢 Серверы: все 5 на связи" in t and "🟢 Копия: сделана · 52 КБ" in t
    assert "🟢 Обслуживание не требуется" in t
    assert "⚠️" not in t and "🟡" not in t and "🔴" not in t


def test_день_с_событиями():
    a = мск(2026, 9, 25, 22, 0)
    evs = [{"kind": "dc_dead", "start": a + 3600, "end": a + 3600 + 130 * 60, "detail": "5"},
           {"kind": "beszel_silent", "start": a + 7200, "end": a + 7200 + 720, "detail": "beta"}]
    t = R.render(_facts(events=evs, ru=(48, 1), backup=("missing", True),
                        maint=["⚠️ Нужна перезагрузка (ядро)", "Автообновления: 94 пакета"]))
    assert "🟡 Сторож: 2 тревоги · 2 ч 22 мин" in t
    assert "🟡 Telegram: DC 5 пропадал 2 ч 10 мин" in t
    assert "🟡 Серверы: beta недоступен 12 мин" in t
    assert "🟡 Россия: недоступен 1 из 48" in t
    assert "🔴 Копия: не сделана — ошибка" in t
    assert "🔧 <b>Обслуживание</b>" in t
    assert "🟡 Нужна перезагрузка (ядро)" in t and "ℹ️ Автообновления: 94 пакета" in t


def test_незакрытая_авария_красная():
    a = мск(2026, 9, 25, 22, 0)
    t = R.render(_facts(events=[{"kind": "engine", "start": a + 80000, "end": None}]))
    assert "🔴 Сторож: 1 тревога · 1 ч 46 мин · идёт сейчас" in t


def test_копия_первая_впереди_не_тревога():
    t = R.render(_facts(backup=("pending",)))
    assert "🟢 Копия: первая ещё впереди" in t


def test_перезагрузка_посреди_суток_без_сравнения():
    t = R.render(_facts(traffic_since_boot=True))
    assert "≈ 7,5 ГБ" in t and "ко вчера" not in t.split("\n")[2]
    assert "счёт с загрузки" in t


def test_имена_экранируются():
    for render in (R.render, R.render_rich):
        t = render(_facts(telemt={"<b>x</b>": 1}, server="<i>s</i>"))
        assert "&lt;b&gt;x&lt;/b&gt;" in t and "&lt;i&gt;s&lt;/i&gt;" in t


def test_без_хаба_и_fail2ban():
    t = R.render(_facts(hub_total=None, bans=None))
    assert "Серверы" not in t
    assert "fail2ban не установлен" in t


def test_rich_таблицами_как_сводка_бота():
    t = R.render_rich(_facts())
    assert t.startswith("<h2>📊 server1</h2>")
    assert "<h3>📶 Трафик · 7,5 ГБ · ↑ 12% ко вчера</h3>" in t
    assert "<tr><th>Клиент</th><th>3x-ui</th><th>telemt</th></tr>" in t
    assert "<tr><td>alice</td><td>2,1 ГБ</td><td>300 МБ</td></tr>" in t
    assert "<tr><td>bob</td><td>600 МБ</td><td>—</td></tr>" in t
    assert "<tr><td>🟢 Сторож</td><td>тревог нет</td></tr>" in t
    assert "Обслуживание не требуется" in t
    # Таблиц три, и каждая закрыта: незакрытый тег Rich Message отвергает целиком.
    assert t.count("<table>") == t.count("</table>") == 3


def test_rich_и_текст_говорят_одно():
    """Оба вида из одних строк: вердикты расходиться не могут."""
    f = _facts(ru=(48, 1), backup=("missing", False))
    rich, plain = R.render_rich(f), R.render(f)
    for фраза in ("недоступен 1 из 48", "не сделана", "Попытки подбора SSH"):
        assert фраза in rich and фраза in plain


# -------------------------------------------------------------- состояние
def test_события_и_сутки(tmp_path, monkeypatch):
    led = L.Ledger(tmp_path / "digest.json")
    led.record("dc_dead", "fire", 1000.0, "5", now=1100.0)
    led.record("dc_dead", "clear", None, now=2000.0)
    assert led.data["events"] == [{"kind": "dc_dead", "start": 1000.0, "end": 2000.0, "detail": "5"}]
    assert led.note_peak(7, now=1500.0) and not led.note_peak(5, now=1600.0)
    led.roll(3000.0, {"nic": 1}, traffic=10, ssh=20, probes=30)
    again = L.Ledger(tmp_path / "digest.json")          # пережило перезапуск
    assert again.data["prev"] == {"traffic": 10, "ssh": 20, "span": None}
    assert again.data["probes_hist"] == [30] and again.data["peak"] == {}
    # Вторые сутки: длина прошлого окна — от прошлого закрытия.
    again.roll(3000.0 + 86400, {"nic": 2}, traffic=11, ssh=21, probes=31)
    assert again.data["prev"]["span"] == 86400


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


def test_копия_по_возрасту_а_не_по_окну(tmp_path, monkeypatch):
    """25.09.2026: сводка за 17 минут сказала «не сделана» — копия суточная."""
    import os
    d = tmp_path / "config"
    d.mkdir()
    timer = tmp_path / "vsm-backup.timer"
    timer.write_text("")
    monkeypatch.setattr(S, "BACKUP_DIR", str(d))
    monkeypatch.setattr(S, "BACKUP_TIMER", str(timer))
    now = time.time()
    assert S.backup(now - 1020, now) == ("pending",)          # таймер свежий, копий не было
    arch = d / "config-20260925.tar.gz"
    arch.write_bytes(b"x" * 2048)
    os.utime(arch, (now - 20 * 3600, now - 20 * 3600))       # вчерашняя ночная — в порядке
    assert S.backup(now - 1020, now) == ("ok", 2048)
    os.utime(arch, (now - 3 * 86400,) * 2)                   # три дня копий нет — тревога
    monkeypatch.setattr(S, "_run", lambda *_a, **_k: "success\n")
    assert S.backup(now - 86400, now) == ("missing", False)


def test_лимиты_молчат_без_лимитов():
    now = time.time()
    assert S.limits([("alice", 5 * 10**9, 0, 0)],
                    [{"username": "carol", "total_octets": 10**9, "data_quota_bytes": 0}], now) == []


def test_лимиты_на_исходе():
    now = time.time()
    out = S.limits([("alice", 95, 100, int((now + 3 * 86400 + 60) * 1000))],
                   [{"username": "dave", "total_octets": 0,
                     "expiration_rfc3339": datetime.fromtimestamp(now + 2 * 86400 + 60, ZoneInfo("UTC")).isoformat()}],
                   now)
    assert any("alice: израсходовано 95%" in s for s in out)
    assert any("alice: срок через 3 дн." in s for s in out)
    assert any("dave: срок через 2 дн." in s for s in out)
