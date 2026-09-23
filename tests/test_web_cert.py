"""
Сверка сертификата WEB не должна зависеть от версии OpenSSL.

ЗАЧЕМ. Установщик включает WEB Proxy так: правит конфиг движка, перезапускает
его и УБЕЖДАЕТСЯ ФАКТОМ, что публичный порт отвечает сертификатом нашего
домена. Не убедился — откатывает конфиг обратно.

Убеждался он grep-ом по строке «CN=<домен>» в выводе s_client. А OpenSSL
печатает subject по-разному:

    OpenSSL 3.0.13 (Ubuntu 24.04)   subject=CN = adk.example.com
    OpenSSL 3.5.5  (Ubuntu 26.04)   subject=CN=adk.example.com

Совпадал только второй вид. Значит на Ubuntu 24.04 WEB Proxy не вставал НИ
РАЗУ: установщик получал отказ, откатывал исправный конфиг и писал «движок не
поднялся с новым конфигом» — хотя движок поднимался прекрасно, а врала
проверка. Замерено 23.09.2026 на двух машинах разом.

Поэтому здесь сертификат СОЗДАЁТСЯ настоящий и разбирается настоящим openssl:
проверка идёт через формат той версии, на которой её запустили. Заглушка с
заранее заготовленной строкой ничего бы не доказала — именно строка и была
неверной.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
БИБЛИОТЕКА = КОРЕНЬ / "lib" / "nginx_web.sh"

pytestmark = pytest.mark.skipif(
    not БИБЛИОТЕКА.is_file()
    or shutil.which("bash") is None
    or shutil.which("openssl") is None,
    reason="нужны lib/nginx_web.sh, bash и openssl",
)

ВЫЗОВ = f'. "{БИБЛИОТЕКА.as_posix()}"\nweb_cert_pem_matches "$1" "$(cat "$2")"'


@pytest.fixture(scope="module")
def сертификат(tmp_path_factory):
    """Самоподписанный сертификат на adk.example.com."""
    каталог = tmp_path_factory.mktemp("cert")
    pem = каталог / "cert.pem"
    ключ = каталог / "key.pem"
    итог = subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(ключ), "-out", str(pem), "-days", "2",
         "-subj", "/CN=adk.example.com",
         "-addext", "subjectAltName=DNS:adk.example.com"],
        capture_output=True, text=True,
    )
    if итог.returncode != 0:
        pytest.skip(f"openssl не выпустил пробный сертификат: {итог.stderr}")
    return pem


def сверить(домен, pem):
    return subprocess.run(
        ["bash", "-c", ВЫЗОВ, "vsm-test", домен, str(pem)],
        capture_output=True, text=True, encoding="utf-8",
    ).returncode


def test_свой_домен_опознан(сертификат):
    assert сверить("adk.example.com", сертификат) == 0, (
        "сверка не опознала собственный сертификат — WEB не встанет"
    )


def test_чужой_домен_отвергнут(сертификат):
    """Обратная сторона. Сверка, говорящая «да» всем, бесполезна."""
    assert сверить("example.com", сертификат) != 0


def test_похожий_домен_отвергнут(сертификат):
    """
    Точки в домене — обычные символы, а не «любой символ» из регулярки.
    Сравнение литеральное, иначе adk-example-com совпал бы с adk.example.com.
    """
    assert сверить("adk-example-com", сертификат) != 0


def test_поддомен_отвергнут(сертификат):
    assert сверить("www.adk.example.com", сертификат) != 0


def test_пустой_домен_отвергнут(сертификат):
    assert сверить("", сертификат) != 0


def test_пустой_ответ_отвергнут(tmp_path):
    """Сервер не ответил — это не «сертификат подошёл»."""
    пусто = tmp_path / "пусто.pem"
    пусто.write_text("", encoding="utf-8")
    assert сверить("adk.example.com", пусто) != 0


def test_мусор_вместо_сертификата_отвергнут(tmp_path):
    мусор = tmp_path / "мусор.pem"
    мусор.write_text("это не сертификат\nи это тоже нет\n", encoding="utf-8")
    assert сверить("adk.example.com", мусор) != 0


def test_формат_subject_у_этой_версии_openssl(сертификат):
    """
    Не проверка кода, а фиксация обстановки: показывает, какой формат печатает
    openssl ЗДЕСЬ. Прежняя сверка ловила только вид без пробелов, и на машине
    с пробелами молча отказывала. Тест всегда проходит — он для отчёта.
    """
    вывод = subprocess.run(
        ["openssl", "x509", "-noout", "-subject", "-in", str(сертификат)],
        capture_output=True, text=True,
    ).stdout.strip()
    assert "adk.example.com" in вывод, вывод
    print(f"\n    формат subject здесь: {вывод}")
