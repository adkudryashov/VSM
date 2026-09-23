"""
Перевод панели на петлю разбирает конфиг по секциям, а не правит вслепую.

ЗАЧЕМ. panel_proxy_localize снимает с telemt_panel собственный TLS: снаружи
админ-форма с валидным сертификатом на нестандартном порту — самый громкий
объект на сервере, и вся работа по маскировке порта telemt после неё теряет
смысл. TLS терминирует nginx на 443 домена панели.

Формат секции [tls] у панели сменился:

    0.x   [tls] cert_file = ... / key_file = ...
    1.x   [tls] mode = "http" | "acme" | "certificate" | "proxy"

Прежняя правка удаляла строку [tls] вместе с ключами. На 1.x это оставило бы
mode висеть в КОРНЕ файла: панель теряет режим транспорта и получает лишний
ключ верхнего уровня.

Соблазн починить это одним `sed s/mode = .*/mode = "http"/` по всему файлу —
ловушка, ради которой и написан этот файл проверок: в 1.x есть ВТОРАЯ секция с
тем же ключом, [privileges] mode = "sudo". Такая правка заменила бы «узкая
политика sudo» на «http», а панель при непонятном значении легко могла бы
откатиться к работе от root. То есть косметическая правка конфига раздавала бы
права. Поэтому здесь у каждой проверки есть сосед: что тронули — и что НЕ
тронули.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
БИБЛИОТЕКА = КОРЕНЬ / "lib" / "nginx_panel_proxy.sh"

pytestmark = pytest.mark.skipif(
    not БИБЛИОТЕКА.is_file() or shutil.which("bash") is None,
    reason="нужны lib/nginx_panel_proxy.sh и bash",
)

КОНФИГ_1X = """\
listen = "0.0.0.0:9444"
base_path = ""
data_dir = "/var/lib/telemt-panel"

[tls]
mode = "acme"

[telemt]
url = "http://127.0.0.1:9091"

[auth]
username = "admin"

[privileges]
mode = "sudo"
"""

КОНФИГ_0X = """\
listen = "0.0.0.0:9444"

[tls]
cert_file = "/etc/letsencrypt/live/r.example.com/fullchain.pem"
key_file = "/etc/letsencrypt/live/r.example.com/privkey.pem"

[auth]
username = "admin"
"""


def перевести(текст, tmp_path, порт="9444"):
    файл = tmp_path / "config.toml"
    файл.write_text(текст, encoding="utf-8")
    ответ = subprocess.run(
        ["bash", "-c",
         f'. "{БИБЛИОТЕКА.as_posix()}"\n'
         f'panel_proxy_localize "{файл.as_posix()}" {порт} r.example.com'],
        capture_output=True, text=True, encoding="utf-8",
    )
    return файл.read_text(encoding="utf-8"), ответ


# --- 1.x -------------------------------------------------------------------

def test_1x_режим_tls_становится_http(tmp_path):
    текст, ответ = перевести(КОНФИГ_1X, tmp_path)
    assert ответ.returncode == 0, ответ.stderr
    assert '[tls]' in текст, "заголовок [tls] удалён — mode повис бы в корне"
    assert 'mode = "http"' in текст, текст
    assert 'mode = "acme"' not in текст, текст


def test_1x_права_панели_не_тронуты(tmp_path):
    """Сосед предыдущей проверки. Слепой sed выдал бы панели root."""
    текст, _ = перевести(КОНФИГ_1X, tmp_path)
    assert 'mode = "sudo"' in текст, (
        "затёрт [privileges] mode — панель получила бы не те права:\n" + текст
    )
    assert текст.count('mode = "http"') == 1, (
        "«http» появился больше одного раза — правка ушла не в ту секцию:\n" + текст
    )


def test_1x_секция_privileges_цела(tmp_path):
    текст, _ = перевести(КОНФИГ_1X, tmp_path)
    строки = текст.splitlines()
    начало = строки.index("[privileges]")
    assert 'mode = "sudo"' in строки[начало:], текст


def test_1x_остальной_конфиг_на_месте(tmp_path):
    текст, _ = перевести(КОНФИГ_1X, tmp_path)
    for кусок in ('base_path = ""', 'data_dir = "/var/lib/telemt-panel"',
                  '[telemt]', 'url = "http://127.0.0.1:9091"',
                  '[auth]', 'username = "admin"'):
        assert кусок in текст, f"{кусок} потерян:\n{текст}"


# --- 0.x -------------------------------------------------------------------

def test_0x_свой_сертификат_убран(tmp_path):
    текст, ответ = перевести(КОНФИГ_0X, tmp_path)
    assert ответ.returncode == 0, ответ.stderr
    assert "cert_file" not in текст, текст
    assert "key_file" not in текст, текст
    assert "[tls]" not in текст, текст


def test_0x_остальной_конфиг_на_месте(tmp_path):
    текст, _ = перевести(КОНФИГ_0X, tmp_path)
    assert "[auth]" in текст and 'username = "admin"' in текст, текст


# --- общее -----------------------------------------------------------------

@pytest.mark.parametrize("конфиг", [КОНФИГ_1X, КОНФИГ_0X])
def test_панель_переезжает_на_петлю(tmp_path, конфиг):
    """Ради этого функция и существует."""
    текст, ответ = перевести(конфиг, tmp_path)
    assert ответ.returncode == 0, ответ.stderr
    assert 'listen = "127.0.0.1:9444"' in текст, текст
    assert '0.0.0.0' not in текст, текст


def test_нечисловой_порт_отвергается(tmp_path):
    """Обратная сторона: строка из аргументов не должна уехать в конфиг."""
    _, ответ = перевести(КОНФИГ_1X, tmp_path, порт="9444; rm -rf /")
    assert ответ.returncode != 0
    assert "числовой порт" in ответ.stderr, ответ.stderr


def test_отсутствующий_файл_называется(tmp_path):
    ответ = subprocess.run(
        ["bash", "-c",
         f'. "{БИБЛИОТЕКА.as_posix()}"\n'
         f'panel_proxy_localize "{(tmp_path / "нет.toml").as_posix()}" 9444 r.example.com'],
        capture_output=True, text=True, encoding="utf-8",
    )
    assert ответ.returncode != 0
    assert "не найден конфиг панели" in ответ.stderr, ответ.stderr


def test_временный_файл_не_остаётся(tmp_path):
    """Забытый config.toml.vsm.XXXX в /etc/telemt-panel — чужой каталог."""
    перевести(КОНФИГ_1X, tmp_path)
    остатки = [p.name for p in tmp_path.iterdir() if p.name != "config.toml"]
    assert остатки == [], f"осталось лишнее: {остатки}"
