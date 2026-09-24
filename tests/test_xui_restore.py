"""
Снимок 3x-ui в суточной копии и его возврат на переустановленный сервер.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Возврат переписывает базу работающей панели и весь
nginx от root. Ошибиться здесь можно тремя дорогими способами, и у каждого
есть проверка:

  вернуть базу без nginx — ссылки клиентов указывают на старые пути, а nginx
  слушает новые: всё «работает», но никто не подключается;

  вернуть копию на панель с чужими доменами — nginx из копии ссылается на
  сертификаты, которых здесь нет;

  сломаться посередине и не откатиться — сервер без рабочей панели вовсе.

ВСЕ СИСТЕМНЫЕ КОМАНДЫ — ЗАГЛУШКИ, все каталоги — временные. Тесты гоняются
на стенде от root, и настоящие systemctl и nginx здесь перезапустили бы живую
панель и чистили бы живой /etc/nginx.
"""
import json
import os
import sqlite3
import subprocess
import tarfile
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
ВОЗВРАТ = КОРЕНЬ / "tools" / "xui-restore.sh"
КОПИЯ = КОРЕНЬ / "tools" / "vsm-backup.sh"

pytestmark = pytest.mark.skipif(os.name == "nt", reason="нужны POSIX-заглушки и bash")

ДОМЕН = "panel.example.org"


def база(путь, sub_path, web_path, клиенты, входящих=2, домен=ДОМЕН):
    c = sqlite3.connect(путь)
    c.executescript("""
        CREATE TABLE settings (id integer PRIMARY KEY, key text, value text);
        CREATE TABLE inbounds (id integer PRIMARY KEY, remark text, port integer,
                               protocol text, enable numeric);
        CREATE TABLE clients (id integer PRIMARY KEY, email text, sub_id text, enable numeric);
    """)
    for k, v in (("subURI", f"https://{домен}{sub_path}"), ("subPath", sub_path),
                 ("webBasePath", web_path)):
        c.execute("insert into settings (key, value) values (?, ?)", (k, v))
    for i in range(входящих):
        c.execute("insert into inbounds (remark, port, protocol, enable) values (?, ?, ?, 1)",
                  (f"вход {i}", 30000 + i, "vless"))
    c.execute("insert into inbounds (remark, port, protocol, enable) values ('awg', 41288, 'amneziawg', 1)")
    for email, sub in клиенты:
        c.execute("insert into clients (email, sub_id, enable) values (?, ?, 1)", (email, sub))
    c.commit()
    c.close()


def сервер(корень: Path, sub_path, web_path, клиенты, метка, входящих=2, домен=ДОМЕН):
    """Раскладка одной установки 3x-ui во временном каталоге."""
    (корень / "etc/x-ui").mkdir(parents=True)
    база(корень / "etc/x-ui/x-ui.db", sub_path, web_path, клиенты, входящих, домен)
    nginx = корень / "etc/nginx/sites-enabled"
    nginx.mkdir(parents=True)
    (nginx / домен).write_text(f"location {sub_path} {{ }}  # {метка}\n")
    for d in ("subpage", "diagnostics", "html"):
        (корень / "var/www" / d).mkdir(parents=True)
    (корень / "var/www/subpage/clash.yaml.tpl").write_text(f"sub: {sub_path}\n")
    (корень / "var/www/diagnostics/index.html").write_text(f"diag {метка}\n")
    (корень / "var/www/diagnostics/гигабайт.bin").write_text("не в снимок\n")
    (корень / "var/www/html/index.html").write_text(f"сайт {метка}\n")
    (корень / "etc/systemd/system").mkdir(parents=True)
    (корень / "etc/systemd/system/mtr-backend.service").write_text(f"--port {метка}\n")
    return корень


def окружение(корень: Path, заглушки: Path):
    env = dict(os.environ)
    env.update({
        "PATH": f"{заглушки}:{env.get('PATH', '')}",
        "XUI_DB": str(корень / "etc/x-ui/x-ui.db"),
        "NGINX_DIR": str(корень / "etc/nginx"),
        "WWW_DIR": str(корень / "var/www"),
        "UNIT_DIR": str(корень / "etc/systemd/system"),
        "XUI_RESTORE_SAVE_DIR": str(корень / "backups"),
        "XUI_RESTORE_WAIT": "2", "XUI_RESTORE_SETTLE": "0", "XUI_RESTORE_TEST": "1",
    })
    return env


@pytest.fixture
def заглушки(tmp_path):
    """
    Поддельные команды. Поведение nginx -t и ответы curl задаются файлами,
    чтобы тест мог сломать одно звено и посмотреть на откат.
    """
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    журнал = tmp_path / "вызовы.log"
    for имя in ("systemctl", "pgrep", "ufw", "chown"):
        (bin_ / имя).write_text(f'#!/bin/sh\necho "{имя} $*" >> "{журнал}"\nexit 0\n')
    (bin_ / "nginx").write_text(
        f'#!/bin/sh\necho "nginx $*" >> "{журнал}"\n'
        f'[ -f "{tmp_path}/nginx-плохой" ] && {{ echo "[emerg] сломано" >&2; exit 1; }}\nexit 0\n')
    # curl: код ответа по последнему аргументу (адресу). Файл «curl-404»
    # содержит подстроку адреса, на которую отвечать 404.
    (bin_ / "curl").write_text(
        f'#!/bin/sh\nfor a; do url="$a"; done\necho "curl $url" >> "{журнал}"\n'
        f'if [ -f "{tmp_path}/curl-404" ] && echo "$url" | grep -qF "$(cat "{tmp_path}/curl-404")"; then\n'
        '  printf 404; exit 0; fi\nprintf 200\n')
    for f in bin_.iterdir():
        f.chmod(0o755)
    return bin_, журнал


def снять(источник: Path, заглушки, tmp_path) -> Path:
    """Снимок функцией xui_snapshot из живого vsm-backup.sh — и архив, как в копии."""
    bin_, _ = заглушки
    stage = tmp_path / "stage"
    stage.mkdir()
    извлечь = f"awk '/^xui_snapshot\\(\\) \\{{/,/^\\}}/' \"{КОПИЯ}\""
    скрипт = (f'warn() {{ echo "$*" >&2; }}\neval "$({извлечь})"\n'
              'xui_snapshot "$1"')
    ответ = subprocess.run(["bash", "-c", скрипт, "x", str(stage)], capture_output=True,
                           text=True, env=окружение(источник, bin_))
    assert ответ.returncode == 0, ответ.stderr
    архив = tmp_path / "config-2026-09-24-000000.tar.gz"
    with tarfile.open(архив, "w:gz") as t:
        t.add(stage / "xui", arcname="xui")
        (tmp_path / "vsm.conf").write_text("X=1\n")
        t.add(tmp_path / "vsm.conf", arcname="etc/vsm/vsm.conf")
    return архив


def вернуть(цель: Path, заглушки, архив: Path, *ключи):
    bin_, _ = заглушки
    return subprocess.run(["bash", str(ВОЗВРАТ), str(архив), "--yes", *ключи],
                          capture_output=True, text=True, env=окружение(цель, bin_))


def клиенты(db):
    c = sqlite3.connect(db)
    rows = [r[0] for r in c.execute("select email from clients order by id")]
    c.close()
    return rows


@pytest.fixture
def пара(tmp_path, заглушки):
    """Старый сервер с клиентами и свежая установка на тех же доменах."""
    старый = сервер(tmp_path / "old", "/СТАРЫЙsub/", "/СТАРАЯпанель/",
                    [("alice", "sub-alice"), ("bob", "sub-bob")], "старый", входящих=5)
    свежий = сервер(tmp_path / "new", "/НОВЫЙsub/", "/НОВАЯпанель/", [], "новый", входящих=2)
    (свежий / "etc/nginx/sites-enabled/лишний.conf").write_text("от свежей установки\n")
    return старый, свежий, снять(старый, заглушки, tmp_path)


# --- снятие ----------------------------------------------------------------

def test_снимок_содержит_базу_и_всё_куда_вписаны_пути(пара):
    _, _, архив = пара
    with tarfile.open(архив) as t:
        names = set(t.getnames())
    for need in ("xui/x-ui.db", f"xui/nginx/sites-enabled/{ДОМЕН}", "xui/www/subpage/clash.yaml.tpl",
                 "xui/www/diagnostics/index.html", "xui/www/html/index.html",
                 "xui/mtr-backend.service"):
        assert need in names, need
    assert "xui/www/diagnostics/гигабайт.bin" not in names, "в снимок попал тяжёлый файл диагностики"


# --- возврат ---------------------------------------------------------------

def test_возврат_приносит_клиентов_и_пути(пара, заглушки):
    _, свежий, архив = пара
    ответ = вернуть(свежий, заглушки, архив)
    assert ответ.returncode == 0, ответ.stdout + ответ.stderr
    assert клиенты(свежий / "etc/x-ui/x-ui.db") == ["alice", "bob"]
    nginx = (свежий / f"etc/nginx/sites-enabled/{ДОМЕН}").read_text()
    assert "/СТАРЫЙsub/" in nginx
    assert (свежий / "var/www/subpage/clash.yaml.tpl").read_text() == "sub: /СТАРЫЙsub/\n"
    assert (свежий / "etc/systemd/system/mtr-backend.service").read_text() == "--port старый\n"


def test_nginx_заменён_целиком_а_не_поверх(пара, заглушки):
    """Лишний файл свежей установки остался бы вторым конфигом."""
    _, свежий, архив = пара
    вернуть(свежий, заглушки, архив)
    assert not (свежий / "etc/nginx/sites-enabled/лишний.conf").exists()


def test_проверка_идёт_подпиской_настоящего_клиента(пара, заглушки):
    _, свежий, архив = пара
    _, журнал = заглушки
    вернуть(свежий, заглушки, архив)
    вызовы = журнал.read_text()
    assert f"https://{ДОМЕН}/СТАРАЯпанель/" in вызовы
    assert f"https://{ДОМЕН}/СТАРЫЙsub/sub-alice" in вызовы
    assert "ufw allow 41288/udp" in вызовы


def test_текущее_сохранено_перед_заменой(пара, заглушки):
    _, свежий, архив = пара
    вернуть(свежий, заглушки, архив)
    сохранённые = list((свежий / "backups").glob("before-restore-*"))
    assert len(сохранённые) == 1
    assert клиенты(сохранённые[0] / "x-ui.db") == []
    assert (сохранённые[0] / "nginx/sites-enabled/лишний.conf").exists()


def test_чужие_домены_отказ_и_ничего_не_тронуто(tmp_path, заглушки, пара):
    _, _, архив = пара
    чужой = сервер(tmp_path / "other", "/x/", "/y/", [], "чужой", домен="other.example.net")
    ответ = вернуть(чужой, заглушки, архив)
    assert ответ.returncode != 0
    assert "Домены не совпадают" in ответ.stderr
    assert клиенты(чужой / "etc/x-ui/x-ui.db") == []
    assert not list((чужой / "backups").glob("before-restore-*")), "отказ начал сохранять и менять"


def test_nginx_не_принял_откат(tmp_path, пара, заглушки):
    _, свежий, архив = пара
    (tmp_path / "nginx-плохой").write_text("1")
    ответ = вернуть(свежий, заглушки, архив)
    assert ответ.returncode != 0
    assert "nginx не принял" in ответ.stderr
    assert клиенты(свежий / "etc/x-ui/x-ui.db") == []
    assert (свежий / "etc/nginx/sites-enabled/лишний.conf").exists()
    assert "/НОВЫЙsub/" in (свежий / f"etc/nginx/sites-enabled/{ДОМЕН}").read_text()


def test_подписка_не_отвечает_откат(tmp_path, пара, заглушки):
    """Главная проверка: ссылки клиентов обязаны работать, иначе возврата нет."""
    _, свежий, архив = пара
    (tmp_path / "curl-404").write_text("sub-alice")
    ответ = вернуть(свежий, заглушки, архив)
    assert ответ.returncode != 0
    assert "подписка клиента" in ответ.stderr
    assert клиенты(свежий / "etc/x-ui/x-ui.db") == []
    assert (свежий / "var/www/subpage/clash.yaml.tpl").read_text() == "sub: /НОВЫЙsub/\n"


def test_пробный_прогон_ничего_не_меняет(пара, заглушки):
    _, свежий, архив = пара
    до = (свежий / "etc/x-ui/x-ui.db").read_bytes()
    ответ = вернуть(свежий, заглушки, архив, "--dry-run")
    assert ответ.returncode == 0, ответ.stderr
    assert (свежий / "etc/x-ui/x-ui.db").read_bytes() == до
    assert not (свежий / "backups").exists() or not list((свежий / "backups").glob("before-*"))


def test_большой_архив_снимок_находится(tmp_path, заглушки, пара):
    """
    Регрессия 24.09.2026. Проверка «снимок есть» шла конвейером tar | grep -q
    при pipefail: grep выходил на совпадении, tar получал SIGPIPE на следующем
    имени, и на настоящем архиве стенда скрипт отвечал «снимка нет». В
    маленьких архивах тестов tar успевал закончить раньше. Здесь база идёт
    ПЕРВОЙ, а за ней тысячи имён — tar пишет после выхода grep обязательно.
    """
    _, свежий, архив = пара
    большой = tmp_path / "config-big.tar.gz"
    распаковано = tmp_path / "unpacked"
    with tarfile.open(архив) as t:
        t.extractall(распаковано)
    хлам = распаковано / "xui/nginx/хлам"
    хлам.mkdir()
    for i in range(3000):
        (хлам / f"f{i:04d}.conf").write_text("# пусто\n")
    with tarfile.open(большой, "w:gz") as t:
        t.add(распаковано / "xui/x-ui.db", arcname="xui/x-ui.db")
        for p in sorted((распаковано / "xui").rglob("*")):
            rel = "xui/" + p.relative_to(распаковано / "xui").as_posix()
            if rel != "xui/x-ui.db":
                t.add(p, arcname=rel, recursive=False)
    ответ = вернуть(свежий, заглушки, большой, "--dry-run")
    assert ответ.returncode == 0, ответ.stderr
    assert "Пробный прогон" in ответ.stdout


def test_архив_без_снимка_отказ(tmp_path, заглушки, пара):
    _, свежий, _ = пара
    пустой = tmp_path / "config-old.tar.gz"
    with tarfile.open(пустой, "w:gz") as t:
        (tmp_path / "a").write_text("1")
        t.add(tmp_path / "a", arcname="etc/vsm/a")
    ответ = вернуть(свежий, заглушки, пустой)
    assert ответ.returncode != 0
    assert "нет снимка 3x-ui" in ответ.stderr
