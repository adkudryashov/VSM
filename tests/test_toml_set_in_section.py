"""
Правка чужого конфига не должна отбирать у службы право его читать.

ЗАЧЕМ. Установщик стека дописывает в /etc/telemt/telemt.toml маскировку и
экспортёр метрик. Файл принадлежит не нам: установщик telemt кладёт его как
root:telemt 640, а служба работает от пользователя telemt и читает конфиг по
группе.

Правка шла связкой `awk > "$file.tmp" && mv "$file.tmp" "$file"`. Временный
файл создаёт оболочка от root по своему umask, поэтому после mv конфиг
становился root:root 600 — и движок переставал читать собственный конфиг:
«Config error: Permission denied (os error 13)», петля перезапусков, этап 3
падает при полностью исправном движке. Замерено 23.09.2026 на установке с нуля.

Дефект был всегда; не кусался он лишь потому, что прежний установщик оставлял
конфиг доступным на чтение всем. Нас прикрывала чужая небрежность, и увидели мы
это ровно тогда, когда её исправили. Поэтому проверка смотрит на ПРАВА, а не на
содержимое: содержимое было верным и в сломанной версии.

У каждой проверки есть обратная сторона — что правка всё-таки состоялась.
Функция, которая не делает ничего, права сохраняет прекрасно.
"""
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
УСТАНОВЩИК = КОРЕНЬ / "stacks" / "telemt.sh"

pytestmark = pytest.mark.skipif(
    not УСТАНОВЩИК.is_file() or shutil.which("bash") is None,
    reason="нужны stacks/telemt.sh и bash",
)

# Установщик самодостаточен и выполняется сверху вниз — подключить его целиком
# нельзя. Вынимаем ровно две функции из ЖИВОГО файла: так проверка отвалится,
# если их переименуют или уберут, а не продолжит молча проверять свою копию.
ИЗВЛЕЧЬ = (
    r"awk '/^_toml_replace\(\) \{/,/^\}/' " + f'"{УСТАНОВЩИК.as_posix()}"; '
    r"awk '/^toml_set_in_section\(\) \{/,/^\}/' " + f'"{УСТАНОВЩИК.as_posix()}"'
)

КОНФИГ = """\
[server]
port = 8444

[server.api]

[censorship]
tls_domain = "adk.example.com"
"""


def bash(скрипт):
    полный = f'eval "$({ИЗВЛЕЧЬ})"\n{textwrap.dedent(скрипт)}'
    return subprocess.run(
        ["bash", "-c", полный], capture_output=True, text=True, encoding="utf-8"
    )


def конфиг(tmp_path, права=0o640):
    файл = tmp_path / "telemt.toml"
    файл.write_text(КОНФИГ, encoding="utf-8")
    файл.chmod(права)
    return файл


def права(файл):
    return файл.stat().st_mode & 0o777


def проверить_функции_нашлись():
    ответ = bash('declare -F toml_set_in_section _toml_replace')
    assert ответ.returncode == 0, (
        "не удалось вынуть функции из stacks/telemt.sh — переименованы?\n"
        + ответ.stderr
    )


def test_функции_вынимаются_из_живого_файла():
    """Если это упало, остальные проверки в этом файле ничего не значат."""
    проверить_функции_нашлись()


def test_замена_существующего_ключа_сохраняет_права(tmp_path):
    файл = конфиг(tmp_path, 0o640)
    ответ = bash(f'toml_set_in_section "{файл.as_posix()}" server port 9999')
    assert ответ.returncode == 0, ответ.stderr
    assert права(файл) == 0o640, (
        f"права стали {oct(права(файл))} вместо 0o640 — служба потеряет конфиг"
    )


def test_замена_существующего_ключа_всё_же_меняет_значение(tmp_path):
    """Обратная сторона: функция, которая ничего не делает, права не портит."""
    файл = конфиг(tmp_path, 0o640)
    bash(f'toml_set_in_section "{файл.as_posix()}" server port 9999')
    текст = файл.read_text(encoding="utf-8")
    assert "port = 9999" in текст
    assert "port = 8444" not in текст


def test_новый_ключ_в_существующей_секции_сохраняет_права(tmp_path):
    файл = конфиг(tmp_path, 0o640)
    ответ = bash(f'toml_set_in_section "{файл.as_posix()}" censorship mask true')
    assert ответ.returncode == 0, ответ.stderr
    assert права(файл) == 0o640
    assert "mask = true" in файл.read_text(encoding="utf-8")


def test_новый_ключ_попадает_в_свою_секцию_а_не_в_соседнюю(tmp_path):
    """Ради этого функция и появилась: tls_domain лежит не в [server]."""
    файл = конфиг(tmp_path, 0o640)
    bash(f'toml_set_in_section "{файл.as_posix()}" censorship mask_port 7444')
    строки = файл.read_text(encoding="utf-8").splitlines()
    начало = строки.index("[censorship]")
    assert "mask_port = 7444" in строки[начало:]


def test_ключ_в_секцию_с_точкой_не_уходит_в_родительскую(tmp_path):
    """
    runtime_edge_enabled живёт в [server.api]. В [server] движок его не
    ищет — ключ молча не подействует, и «События» в панели останутся
    выключенными при ключе, видном глазом в файле.
    """
    файл = конфиг(tmp_path, 0o640)
    ответ = bash(
        f'toml_set_in_section "{файл.as_posix()}" server.api runtime_edge_enabled true'
    )
    assert ответ.returncode == 0, ответ.stderr
    строки = файл.read_text(encoding="utf-8").splitlines()
    api = строки.index("[server.api]")
    assert строки[api + 1] == "runtime_edge_enabled = true", строки
    assert "runtime_edge_enabled = true" not in строки[:api], строки
    assert строки.count("[server.api]") == 1, "секция задвоилась"


def test_отсутствующая_секция_дописывается_и_не_трогает_права(tmp_path):
    """Ветка дозаписи (>>) прав не меняет, но проверить её всё равно надо."""
    файл = конфиг(tmp_path, 0o640)
    ответ = bash(f'toml_set_in_section "{файл.as_posix()}" metrics listen 9090')
    assert ответ.returncode == 0, ответ.stderr
    assert права(файл) == 0o640
    текст = файл.read_text(encoding="utf-8")
    assert "[metrics]" in текст and "listen = 9090" in текст


@pytest.mark.parametrize("исходные", [0o600, 0o640, 0o644])
def test_сохраняются_любые_права_а_не_подставляются_свои(tmp_path, исходные):
    """Мы не знаем, какими правами чужой установщик положит конфиг завтра."""
    файл = конфиг(tmp_path, исходные)
    bash(f'toml_set_in_section "{файл.as_posix()}" server port 9999')
    assert права(файл) == исходные


def test_остальные_ключи_секции_на_месте(tmp_path):
    """Правка одного ключа не должна усекать чужой конфиг."""
    файл = конфиг(tmp_path, 0o640)
    bash(f'toml_set_in_section "{файл.as_posix()}" censorship mask true')
    текст = файл.read_text(encoding="utf-8")
    assert 'tls_domain = "adk.example.com"' in текст
    assert "[server.api]" in текст
    assert "port = 8444" in текст


def test_временный_файл_не_остаётся_рядом(tmp_path):
    """Забытый telemt.toml.tmp рядом с конфигом — чужой каталог, чужие глаза."""
    файл = конфиг(tmp_path, 0o640)
    bash(f'toml_set_in_section "{файл.as_posix()}" server port 9999')
    остатки = [p.name for p in tmp_path.iterdir() if p.name != "telemt.toml"]
    assert остатки == [], f"осталось лишнее: {остатки}"
