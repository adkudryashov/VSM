"""
Прогон чистой логики сторожа без сервера, сети и Telegram.

Каждая проверка парная: показывает, что правило срабатывает И что оно НЕ
срабатывает там, где не должно. Проверка, умеющая только подтверждать, ничего
не доказывает.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bots"))

from telemt.watchdog.incidents import CLEAR, FIRE, REPEAT, Flap, WatchState
from telemt.watchdog.quota import Quota, retry_after_seconds
from telemt.watchdog.upstreams import Counters, HardFailWatch, extract

ok = fail = 0


def check(name, got, want):
    global ok, fail
    if got == want:
        ok += 1
        print(f"  ok   {name}")
    else:
        fail += 1
        print(f"  ПРОВАЛ {name}: получено {got!r}, ожидалось {want!r}")


print("== Flap: тревога, повтор, отбой ==")
f = Flap(threshold=3)
check("два плохих — молчим", [f.update(True, now=t) for t in (0, 1)], [None, None])
check("третий плохой — тревога", f.update(True, now=2), FIRE)
check("четвёртый — молчим, рано", f.update(True, now=3), None)
check("через 29 мин — ещё молчим", f.update(True, now=2 + 29 * 60), None)
check("через 30 мин — напоминание", f.update(True, now=2 + 30 * 60), REPEAT)
check("сразу следом — молчим", f.update(True, now=2 + 30 * 60 + 5), None)
check("хороший — отбой", f.update(False, now=2 + 31 * 60), CLEAR)
check("ещё хороший — молчим", f.update(False, now=2 + 32 * 60), None)
check("длительность аварии, мин", f.duration(now=2 + 31 * 60), 31)

f2 = Flap(threshold=3)
check("отбой без тревоги не шлётся", f2.update(False, now=0), None)

print("== Длительность считается от первого плохого опроса, не от тревоги ==")
g = Flap(threshold=3)
g.update(True, now=0)     # авария началась здесь
g.update(True, now=60)
g.update(True, now=120)   # а тревога ушла только здесь
check("тревога на третьем опросе", g.firing, True)
check("длительность от начала аварии", g.duration(now=180), 3)
check("а не от момента тревоги", g.duration(now=180) == int((180 - g.since) / 60), False)
check("отбой", g.update(False, now=180), CLEAR)
check("после отбоя длительность полная", g.duration(now=180), 3)
g2 = Flap(threshold=3)
g2.update(True, now=0); g2.update(False, now=60)   # моргнуло и прошло
g2.update(True, now=120)
check("прерванная цепочка начинает отсчёт заново", g2.bad_since, 120)

print("== Flap: состояние переживает перезапуск ==")
f3 = Flap.from_dict(Flap(threshold=3, bad=2, firing=True, since=100, last_notify=100).to_dict(), 3)
check("firing сохранился", f3.firing, True)
check("since сохранился", f3.since, 100)
f4 = Flap.from_dict({"bad": 1, "firing": True}, 3)  # состояние прежней версии
check("старое состояние читается", (f4.firing, f4.since), (True, 0.0))
check("без since длительность 0", f4.duration(now=999999), 0)

print("== extract: разбор ответа движка ==")
zero = {"connect_attempt_total": 100, "connect_fail_total": 50,
        "connect_failfast_hard_error_total": 5, "connect_success_total": 50}
check("из /v1/stats/upstreams", extract({"data": {"zero": zero}}), Counters(100, 50, 5))
check("из /v1/stats/zero/all", extract({"data": {"upstream": zero}}), Counters(100, 50, 5))
check("полей нет — None", extract({"data": {"summary": {"x": 1}}}), None)
check("пустой ответ — None", extract({}), None)
check("неполный блок — None", extract({"data": {"zero": {"connect_attempt_total": 1}}}), None)

print("== HardFailWatch: дельта ==")
w = HardFailWatch()
check("первый опрос — измерения нет", w.update(Counters(100, 50, 0), "t1").has_rate, False)
d = w.update(Counters(200, 90, 30), "t1")
check("второй опрос — есть", d.has_rate, True)
check("доля жёстких", round(d.hard_pct), 30)
check("доля повторов (справка)", round(d.fail_pct), 40)

check("перезапуск движка — измерения нет",
      w.update(Counters(10, 5, 1), "t2").has_rate, False)
check("после перезапуска считаем снова",
      w.update(Counters(110, 25, 1), "t2").has_rate, True)

w2 = HardFailWatch()
w2.update(Counters(100, 10, 0), "t1")
check("счётчики уехали назад — измерения нет",
      w2.update(Counters(50, 5, 0), "t1").has_rate, False)

w3 = HardFailWatch()
w3.update(Counters(100, 10, 0), "t1")
check("ни одной попытки — измерения НЕТ (не ноль процентов)",
      w3.update(Counters(100, 10, 0), "t1").has_rate, False)

w4 = HardFailWatch()
w4.update(Counters(100, 10, 0), "t1")
check("движок ответил урезанно — снимок цел",
      w4.update(None, "t1").has_rate, False)
check("и следующая дельта считается",
      w4.update(Counters(200, 20, 0), "t1").has_rate, True)

print("== Контрольный случай: наши боевые числа со стенда ==")
w5 = HardFailWatch()
w5.update(Counters(295614, 153874, 0), "t1")
d5 = w5.update(Counters(295933, 153878, 0), "t1")
check("исправный прокси: жёстких 0%", round(d5.hard_pct), 0)
check("исправный прокси: повторов 1% — тревоги не будет", round(d5.fail_pct), 1)
check("порог 20% не пройден", d5.hard_pct > 20.0, False)
w6 = HardFailWatch()
w6.update(Counters(295614, 153874, 0), "t1")
d6 = w6.update(Counters(295933, 154078, 200), "t1")
check("сломанный выход: жёстких 63% — тревога будет", d6.hard_pct > 20.0, True)

print("== Quota: реестр трат ==")
q = Quota()
check("пусто — тратить можно", q.can_spend(10, False, now=0), None)
q.record(10, now=0)
q.record(240, now=10)
check("потрачено", q.spent(now=20), 250)
check("бюджет исчерпан", q.can_spend(10, False, now=20) is not None, True)
check("с токеном ещё можно", q.can_spend(10, True, now=20), None)
check("через час окно очистилось", q.can_spend(10, False, now=3700), None)

q2 = Quota()
q2.note_manual(now=0)
check("ручная сразу — нельзя", q2.manual_ready_in(now=10), 50)
check("через минуту — можно", q2.manual_ready_in(now=61), 0)

q4 = Quota()
check("не тратили — расписание с нуля", q4.last_spend(), 0.0)
q4.record(20, now=100); q4.record(20, now=1900)
check("последняя трата — самая свежая", q4.last_spend(), 1900)

q3 = Quota()
q3.block_for(300, now=0)
check("сервис запретил", q3.can_spend(1, False, now=10) is not None, True)
check("после срока — можно", q3.can_spend(1, False, now=400), None)
check("реестр переживает перезапуск",
      Quota.from_dict(q3.to_dict()).blocked_until, q3.blocked_until)

print("== retry_after_seconds ==")
check("Retry-After", retry_after_seconds({"retry-after": "120"}), 120)
check("X-RateLimit-Reset", retry_after_seconds({"x-ratelimit-reset": "45"}), 45)
check("мусор — ноль", retry_after_seconds({"retry-after": "потом"}), 0)
check("нет заголовков — ноль", retry_after_seconds({}), 0)
check("абсурд обрезается", retry_after_seconds({"retry-after": "999999"}), 7200)

print("== Чтение чужого вердикта MTProxyL ==")
import json as _json, tempfile, os
from telemt.watchdog import mtproxyl

def wr(obj):
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        _json.dump(obj, fh)
    return path

good = wr({"total_probes": 20, "success_probes": 17, "percentage": 85.0,
           "level": "green", "checked_at": "2026-08-14T12:34:55Z", "error": "",
           "target": "1.2.3.4:8444", "probes":
           [{"tls_success": True}] * 17 +
           [{"tls_success": False, "error": "соединение не установлено"}] * 2 +
           [{"tls_success": False, "error": "зонд не ответил вовремя"}]})
v = mtproxyl.read_verdict(good)
check("успех/всего", (v["success"], v["total"]), (17, 20))
check("процент", v["pct"], 85.0)
check("причины разобраны", sorted(v["reasons"].items()),
      [("зонд не ответил вовремя", 1), ("соединение не установлено", 2)])
from datetime import datetime, timezone
check("метка времени разобрана", int(v["checked_at"]),
      int(datetime(2026, 8, 14, 12, 34, 55, tzinfo=timezone.utc).timestamp()))
check("источник помечен", v["source"], "mtproxyl")
check("нашей квоте списывать нечего", v["charged"], 0)

check("файла нет — данных нет", mtproxyl.read_verdict("/нет/такого"), None)
bad = wr({"не": "то"})
check("чужая структура — данных нет", mtproxyl.read_verdict(bad), None)
zero = wr({"total_probes": 0, "success_probes": 0, "percentage": 0, "error": "",
           "checked_at": "2026-08-14T12:00:00Z", "probes": []})
check("ни один зонд не взялся — НЕ ноль процентов", mtproxyl.read_verdict(zero), None)
err = wr({"error": "сервис проверки не отвечает", "checked_at": "2026-08-14T12:00:00Z"})
ev = mtproxyl.read_verdict(err)
check("ошибка MTProxyL распознана", ev.get("error"), "сервис проверки не отвечает")
check("и это не вердикт о доступности", "pct" in ev, False)
broken = wr("не словарь")
check("мусор в файле — данных нет", mtproxyl.read_verdict(broken), None)
for p in (good, bad, zero, err, broken):
    os.unlink(p)
check("источника нет — available False", mtproxyl.available("/нет/такого"), False)

print("== WatchState: новые поля сохраняются ==")
st = WatchState.from_dict({}, 3)
st.hard_fails.update(True, now=0); st.hard_fails.update(True, now=1); st.hard_fails.update(True, now=2)
st.quota.record(10, now=0)
back = WatchState.from_dict(st.to_dict(), 3)
check("тревога жёстких отказов сохранилась", back.hard_fails.firing, True)
check("квота сохранилась", back.quota.spent(now=1), 10)
check("старый файл состояния читается", WatchState.from_dict(
    {"engine": {"bad": 0, "firing": False}}, 3).hard_fails.firing, False)

print(f"\nИтог: успешно {ok}, провалено {fail}")
sys.exit(1 if fail else 0)
