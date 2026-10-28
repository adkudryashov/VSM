"""
Список админов бота: числа через запятую или пробел.

ЗАЧЕМ. Пробелы раньше выбрасывались, и «123 456» становилось одним чужим
номером 123456 — бот вставал и молча не отвечал ни одному из админов.
«123;456» и «@имя» валили бота при запуске ошибкой разбора, а без меню
(переменной окружения) список не проверялся вовсе.

Функция вырезается из установщика и гоняется в bash отдельно: весь
stacks/bots.sh ставит пакеты и службы.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

УСТАНОВЩИК = Path(__file__).resolve().parent.parent / "stacks" / "bots.sh"
pytestmark = pytest.mark.skipif(not shutil.which("bash"), reason="нужен bash")


def _функция():
    строки = УСТАНОВЩИК.read_text(encoding="utf-8").splitlines()
    i = строки.index("normalize_ids() {")
    j = строки.index("}", i)
    return "\n".join(строки[i:j + 1])


def norm(value):
    r = subprocess.run(["bash", "-c", _функция() + '\nnormalize_ids "$1"', "_", value],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


@pytest.mark.parametrize("value, want", [
    ("123", "123"),
    ("123,456", "123,456"),
    ("123 456", "123,456"),          # прежде: один номер 123456
    (" 123 ,  456 ,", "123,456"),
    ("123\t456", "123,456"),
    ("[123,456]", "123,456"),        # значение из старого .env
])
def test_верные_списки(value, want):
    assert norm(value) == want


@pytest.mark.parametrize("value", ["", " ", ",", "123;456", "@user", "12a", "-100123"])
def test_неверные_отвергаются(value):
    assert norm(value) is None
