"""
Распознавание ночного автообновления системы.

ЗАЧЕМ ЭТО ПОКРЫВАТЬ. Сторож два дня подряд писал «движок перезапустился», и
владелец каждый раз выяснял причину заново. Причина оказалась одна:
apt-daily-upgrade ставит обновления, needrestart дёргает всё, что слинковано
с обновлённой библиотекой. Теперь сторож называет её сам.

Мы читаем ЧУЖОЙ файл — /var/log/apt/history.log принадлежит apt, и его формат
может измениться. Поэтому проверяется не только распознавание, но и обратное:
любая неудача разбора обязана давать «не знаю», а не исключение посреди
отправки тревоги.
"""

from datetime import datetime
from pathlib import Path

from telemt.watchdog import upgrades

# Настоящий кусок журнала со стенда, 03.09.2026. Формат подсмотрен, а не
# выдуман: выдуманный формат проверял бы наши же представления о нём.
ЖУРНАЛ = """Start-Date: 2026-09-03  06:23:10
Commandline: /usr/bin/unattended-upgrade
Upgrade: libpam-runtime:amd64 (1.7.0-5ubuntu3.1, 1.7.0-5ubuntu3.2), libpam-modules:amd64 (1.7.0-5ubuntu3.1, 1.7.0-5ubuntu3.2)
End-Date: 2026-09-03  06:23:16

Start-Date: 2026-09-03  06:23:17
Commandline: /usr/bin/unattended-upgrade
Upgrade: sudo-rs:amd64 (0.2.13-0ubuntu1, 0.2.13-0ubuntu1.2)
End-Date: 2026-09-03  06:23:18
"""

МОМЕНТ = datetime(2026, 9, 3, 6, 23, 30).timestamp()


def журнал(tmp_path, text=ЖУРНАЛ):
    p = tmp_path / "history.log"
    p.write_text(text, encoding="utf-8")
    return p


def test_свежее_обновление_узнаётся(tmp_path):
    got = upgrades.recent_packages(path=журнал(tmp_path), now=МОМЕНТ)
    assert got[:3] == ["libpam-runtime", "libpam-modules", "sudo-rs"]


def test_версии_и_архитектура_в_имя_не_лезут(tmp_path):
    """В сообщении нужен пакет, а не строка из журнала целиком."""
    got = upgrades.recent_packages(path=журнал(tmp_path), now=МОМЕНТ)
    assert all(":" not in имя and "(" not in имя for имя in got)


def test_старое_обновление_не_считается(tmp_path):
    """
    Обратная сторона: без неё проверка выше прошла бы и у функции, которая
    возвращает всё подряд, — и сторож объяснял бы любой перезапуск вчерашним
    обновлением.
    """
    сутки_спустя = МОМЕНТ + 24 * 3600
    assert upgrades.recent_packages(path=журнал(tmp_path), now=сутки_спустя) == []


def test_ручная_установка_причиной_не_называется(tmp_path):
    """
    Поставил человек пакеты руками — он и так знает, что сделал. Называть это
    причиной значит объяснять очевидное и прятать настоящую причину.
    """
    ручками = ЖУРНАЛ.replace("/usr/bin/unattended-upgrade", "apt install curl")
    assert upgrades.recent_packages(path=журнал(tmp_path, ручками), now=МОМЕНТ) == []


def test_нет_файла_значит_не_знаю(tmp_path):
    assert upgrades.recent_packages(path=tmp_path / "нет-такого", now=МОМЕНТ) == []


def test_чужой_формат_не_роняет(tmp_path):
    """
    Правило то же, что для вердикта MTProxyL: нечитаемое — это «данных нет».
    Исключение здесь оборвало бы отправку самого сообщения о перезапуске,
    то есть подсказка утащила бы за собой то, что поясняет.
    """
    for мусор in ("", "совсем не журнал\n", "Start-Date: вчера\nUpgrade: что-то\n",
                  "Start-Date: 2026-09-03  06:23:10\n"):
        assert upgrades.recent_packages(path=журнал(tmp_path, мусор), now=МОМЕНТ) == []


def test_список_ограничен(tmp_path):
    """
    В сообщение идёт подсказка, а не отчёт apt. Ночью обновляется и два
    десятка пакетов — строка стала бы нечитаемой.
    """
    много = ", ".join("pkg%d:amd64 (1, 2)" % i for i in range(20))
    текст = ("Start-Date: 2026-09-03  06:23:10\n"
             "Commandline: /usr/bin/unattended-upgrade\n"
             "Upgrade: " + много + "\n")
    got = upgrades.recent_packages(path=журнал(tmp_path, текст), now=МОМЕНТ)
    assert len(got) == 4
