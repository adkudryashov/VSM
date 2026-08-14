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
