"""
Общая обвязка прогонов.

Пакет bots/ не устанавливается, а лежит рядом, и модули внутри него ссылаются
друг на друга без префикса (`from config import settings`). Поэтому путь
добавляется здесь, один раз на весь прогон, а не в каждом файле.
"""
import sys
from pathlib import Path

BOTS = Path(__file__).resolve().parents[1] / "bots"
if str(BOTS) not in sys.path:
    sys.path.insert(0, str(BOTS))

import pytest


@pytest.fixture(autouse=True)
def _digest_ledger_in_tmp(tmp_path, monkeypatch):
    """
    Состояние сводки — во временный файл, а не в bots/data/digest.json.

    Любая тревога сторожа пишет событие в сводку (Watchdog._fire_or_clear), и
    тесты, поднимающие тревогу, дописывали выдуманные аварии в БОЕВОЙ файл
    сервера, где их гоняют, — они всплыли бы в вечерней сводке. Замечено
    28.09.2026 при добавлении тестов тревоги о писателях.
    """
    if "telemt.digest.ledger" in sys.modules or "telemt.watchdog.monitor" in sys.modules:
        from telemt.digest import ledger
        monkeypatch.setattr(ledger, "_shared", ledger.Ledger(tmp_path / "digest.json"))
    yield


@pytest.fixture
def verdict_file(tmp_path):
    """
    Отдаёт функцию, которая кладёт вердикт MTProxyL во временный файл.

    Пишем именно файлом, а не подсовываем разобранный словарь: половина смысла
    этого модуля — пережить чужой JSON, каким бы он ни пришёл, и подмена на
    готовый объект проверяла бы совсем не то.
    """
    def write(text: str) -> str:
        path = tmp_path / "last.json"
        path.write_text(text, encoding="utf-8")
        return str(path)
    return write
