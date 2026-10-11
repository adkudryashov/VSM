"""
Сайт-заглушка (tools/stub-site.py, lib/stub_site.sh).

Генератор: сайт повторяем по числу, свой у каждого числа, не ходит наружу и не
выдаёт, чем на самом деле занят сервер. Установщик: прежняя страница уходит в
копию и возвращается, .well-known (продление сертификата) не трогается.
systemctl подменён заглушкой впереди PATH — живой сервер тест не трогает.
"""
import datetime as dt
import importlib.util
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stub", ROOT / "tools" / "stub-site.py")
stub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stub)

DOMAIN = "adk.egevad.se"
TODAY = dt.date(2026, 10, 11)


def build(tmp_path, seed=4242, date=TODAY, domain=DOMAIN, name="site"):
    out = tmp_path / name
    files = stub.build(stub.Club(domain, seed), date, out)
    return out, files


def texts(out):
    return {p.relative_to(out).as_posix(): p.read_text(encoding="utf-8")
            for p in out.rglob("*") if p.is_file()}


# ------------------------------------------------------------------ генератор
def test_одно_число_один_сайт_другое_число_другой(tmp_path):
    a, _ = build(tmp_path, name="a")
    b, _ = build(tmp_path, name="b")
    c, _ = build(tmp_path, seed=4243, name="c")
    assert texts(a) == texts(b)
    assert texts(a)["index.html"] != texts(c)["index.html"]


def test_название_из_домена():
    assert stub.Club(DOMAIN, 1).name.startswith("Egevad")
    assert stub.Club("x.gnilron.se", 1).place == "Gnilron"
    # Не слово — название выдумывается, но всё равно есть.
    club = stub.Club("x.k3x9.se", 1)
    assert club.place != "K3x9" and len(club.name) > 4


def test_ничего_наружу_и_ни_слова_о_деле(tmp_path):
    out, _ = build(tmp_path)
    for name, text in texts(out).items():
        low = text.lower()
        for word in ("3x-ui", "xray", "telemt", "vpn", "proxy", "reality", "mtproto"):
            assert word not in low, (name, word)
        # Единственный адрес — пространство имён SVG; ни скриптов, ни шрифтов.
        assert set(re.findall(r"https?://[^\s\"')]+", text)) <= {"http://www.w3.org/2000/svg"}, name
        assert "<script" not in low, name


def test_счёт_только_у_сыгранных_и_таблица_сходится():
    club = stub.Club(DOMAIN, 4242)
    games = stub.schedule(club, 2026)
    assert len(games) == 132                                    # 12 команд, два круга
    rows = stub.table(club, games, TODAY)
    assert sum(r["w"] for r in rows) == sum(r["l"] for r in rows)
    assert sum(r["gf"] for r in rows) == sum(r["ga"] for r in rows)
    played = sum(1 for g in games if g["date"] < TODAY)
    assert sum(r["p"] for r in rows) == 2 * played


def test_будущие_счета_не_видны(tmp_path):
    out, _ = build(tmp_path)
    m = texts(out)["matcher.html"]
    upcoming = m.split("<h2>Spelade</h2>")[0]
    assert "Kommande" in upcoming
    assert not re.search(r'class="sc">\d', upcoming)


def test_новости_не_из_будущего(tmp_path):
    out, files = build(tmp_path)
    dates = [dt.date.fromisoformat(f.split("/")[1][:10]) for f in files if f.startswith("nyheter/")]
    assert dates and max(dates) <= TODAY


@pytest.mark.parametrize("date,expect", [
    (dt.date(2026, 1, 5), "Seriepremiären"),
    (dt.date(2026, 12, 1), "Säsongen 2026 är över"),
])
def test_межсезонье(tmp_path, date, expect):
    out, _ = build(tmp_path, date=date)
    assert expect in texts(out)["index.html"]


def test_ссылки_внутри_сайта_ведут_на_файлы(tmp_path):
    out, _ = build(tmp_path)
    for name, text in texts(out).items():
        if not name.endswith(".html"):
            continue
        base = (out / name).parent
        for href in re.findall(r'(?:href|src)="([^"#:]+)"', text):
            assert (base / href).resolve().is_file(), (name, href)


# ------------------------------------------------------------------ установщик
pytestmark_bash = pytest.mark.skipif(not shutil.which("bash") or not shutil.which("python3"),
                                     reason="нужны bash и python3")


def _env(tmp_path):
    b = tmp_path / "bin"
    b.mkdir(exist_ok=True)
    (b / "systemctl").write_text('#!/bin/sh\necho "$@" >> "$LOG"\nexit 0\n')
    (b / "systemctl").chmod(0o755)
    conf = tmp_path / "vsm"
    conf.mkdir(exist_ok=True)
    (conf / "telemt.conf").write_text(f"DOMAIN_PANEL={DOMAIN}\n")
    return dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", LOG=str(tmp_path / "log"),
                STUB_ROOT=str(tmp_path / "www"), STUB_CONF=str(conf / "stub-site.conf"),
                STUB_FILES=str(conf / "stub-site.files"), STUB_BACKUP_DIR=str(tmp_path / "bak"),
                STUB_STACK_CONF=str(conf / "telemt.conf"), STUB_SYSTEMD=str(tmp_path / "units"))


def sh(env, script):
    r = subprocess.run(["bash", "-c", f'. "{(ROOT / "lib" / "stub_site.sh").as_posix()}"\n{script}'],
                       env=env, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr


@pytestmark_bash
def test_замена_копия_и_возврат(tmp_path):
    env = _env(tmp_path)
    (tmp_path / "units").mkdir()
    www = tmp_path / "www"
    (www / ".well-known" / "acme-challenge").mkdir(parents=True)
    (www / ".well-known" / "acme-challenge" / "tok").write_text("acme")
    (www / "index.html").write_text("<title>System Upgrade in Progress</title>")
    (www / "assets").mkdir()
    (www / "assets" / "a.css").write_text("x")

    assert sh(env, "stub_site_state")[1] == "чужая страница"
    rc, _, err = sh(env, "stub_site_apply")
    assert rc == 0, err
    assert sh(env, "stub_site_state")[1] == "наш сайт"
    assert "Egevad" in (www / "index.html").read_text(encoding="utf-8")
    assert not (www / "assets").exists()                        # шаблон убран
    assert (www / ".well-known" / "acme-challenge" / "tok").read_text() == "acme"
    assert len(list((tmp_path / "bak").iterdir())) == 1
    assert (tmp_path / "units" / "vsm-stub-site.timer").exists()
    assert "enable" in (tmp_path / "log").read_text()

    # Обновление своего сайта: копию не множит, своё убирает по списку,
    # чужой файл владельца рядом не трогает, число не меняет.
    seed = re.search(r"STUB_SEED=(\d+)", Path(env["STUB_CONF"]).read_text()).group(1)
    (www / "nyheter" / "stale.html").write_text("старое")
    Path(env["STUB_FILES"]).write_text(Path(env["STUB_FILES"]).read_text() + "nyheter/stale.html\n")
    (www / "owner.txt").write_text("моё")
    assert sh(env, "stub_site_refresh")[0] == 0
    assert not (www / "nyheter" / "stale.html").exists()
    assert (www / "owner.txt").exists()
    assert len(list((tmp_path / "bak").iterdir())) == 1
    assert f"STUB_SEED={seed}" in Path(env["STUB_CONF"]).read_text()

    # Новый облик — новое число.
    assert sh(env, "stub_site_apply new")[0] == 0
    assert f"STUB_SEED={seed}" not in Path(env["STUB_CONF"]).read_text()

    rc, out, err = sh(env, "stub_site_restore")
    assert rc == 0, err
    assert "System Upgrade" in (www / "index.html").read_text()
    assert (www / "assets" / "a.css").exists()
    assert (www / ".well-known" / "acme-challenge" / "tok").exists()
    assert not Path(env["STUB_CONF"]).exists()
    assert not (tmp_path / "units" / "vsm-stub-site.timer").exists()


@pytestmark_bash
def test_вернувшийся_шаблон_виден_и_обновление_его_не_трогает(tmp_path):
    env = _env(tmp_path)
    (tmp_path / "units").mkdir()
    assert sh(env, "stub_site_apply")[0] == 0
    (tmp_path / "www" / "index.html").write_text("шаблон снова")
    assert sh(env, "stub_site_state")[1] == "чужая страница"
    # Таймер молчит: вернуть — дело сверки, она об этом и скажет.
    assert sh(env, "stub_site_refresh")[0] == 0
    assert (tmp_path / "www" / "index.html").read_text() == "шаблон снова"


@pytestmark_bash
def test_без_домена_ничего_не_трогает(tmp_path):
    env = _env(tmp_path)
    Path(env["STUB_STACK_CONF"]).write_text("")
    www = tmp_path / "www"
    www.mkdir()
    (www / "index.html").write_text("было")
    rc, _, err = sh(env, "stub_site_apply")
    assert rc != 0 and "домен" in err
    assert (www / "index.html").read_text() == "было"
