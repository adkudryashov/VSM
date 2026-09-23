"""
Секции конфига движка при включении WEB: что меняем и чего НЕ трогаем.

ЗАЧЕМ. Включение WEB Proxy переписывает чужой конфиг /etc/telemt/telemt.toml,
и оба здешних дефекта были не в том, что мы написали, а в том, что задели
по дороге.

ПЕРВЫЙ. Правка удаляла строку [server] и ставила listener-ы на её место. Всё,
что лежало в секции ВЫШЕ ключа port, осиротело — ключи уезжали в предыдущую
секцию. На установке 23.09.2026 туда уехали metrics_listen и
metrics_whitelist, и движок сказал прямо:
    WARN Unknown config key ignored key=general.modes.metrics_listen
то есть экспортёр метрик молча выключился. На стенде не проявилось только по
везению в порядке правок: там метрики дописали уже после WEB.

ВТОРОЙ. Установщик telemt при повторном запуске обновляет порт правилом
    /^[ \t]*port[ \t]*=/ { print "port = " port }
без оглядки на секцию — переписывается КАЖДАЯ строка «port =». С включённым
WEB их две, у слушателя mtproxy и у слушателя web, обе получают один номер, и
движок умирает с «Address already in use». Чужой код не исправить, поэтому
чиним следствие сразу после его запуска.

Обе стороны у каждой проверки: что починили — и что оставили в покое. Вторая
половина здесь важнее первой. Наивная правка «поставить всем port нужный
номер» прошла бы половину проверок и сломала бы слушателя mtproxy, а наивная
правка по ключу listen задела бы [server.api].
"""
import hashlib
import shutil
import subprocess
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
БИБЛИОТЕКА = КОРЕНЬ / "lib" / "nginx_web.sh"

pytestmark = pytest.mark.skipif(
    not БИБЛИОТЕКА.is_file() or shutil.which("bash") is None,
    reason="нужны lib/nginx_web.sh и bash",
)

ДО_WEB = """\
[general.modes]
classic = false
tls = true

[server]
metrics_whitelist = ["127.0.0.1/32"]
metrics_listen = "127.0.0.1:9090"
port = 8444

[server.api]
enabled = true
listen = "127.0.0.1:9091"

[censorship]
mask = true
tls_domain = "adk.example.com"
"""

# Ровно то, что оставляет за собой чужой установщик: оба слушателя на 8444.
СЛОМАННЫЙ = """\
[server]
metrics_listen = "127.0.0.1:9090"

[[server.listeners]]
ip = "0.0.0.0"
port = 8444
transport = "mtproxy"
proxy_protocol = false

[[server.listeners]]
ip = "127.0.0.1"
port = 8444
transport = "web"
reuse_allow = false

[server.api]
enabled = true
listen = "127.0.0.1:9091"
"""


def включить_web(текст, tmp_path):
    файл = tmp_path / "telemt.toml"
    файл.write_text(текст, encoding="utf-8")
    скрипт = (
        f'WEB_TOML="$1"\n. "{БИБЛИОТЕКА.as_posix()}"\n'
        'web_toml_users() { echo hello; }\n'
        'web_public_addr() { echo "1.2.3.4:443"; }\n'
        'web_toml_enable adk.example.com'
    )
    ответ = subprocess.run(
        ["bash", "-c", скрипт, "vsm-test", файл.as_posix()],
        capture_output=True, text=True, encoding="utf-8",
    )
    return файл.read_text(encoding="utf-8"), ответ


def починить(текст, tmp_path, порт="15080"):
    файл = tmp_path / "telemt.toml"
    файл.write_text(текст, encoding="utf-8")
    ответ = subprocess.run(
        ["bash", "-c",
         f'. "{БИБЛИОТЕКА.as_posix()}"\nweb_listener_port_repair "$1" "$2"',
         "vsm-test", файл.as_posix(), порт],
        capture_output=True, text=True, encoding="utf-8",
    )
    return файл.read_text(encoding="utf-8"), ответ


def слушатели(текст):
    """{transport: port} из всех блоков [[server.listeners]]."""
    итог, блок, транспорт, порт = {}, False, None, None
    for строка in текст.splitlines():
        голая = строка.strip()
        if голая == "[[server.listeners]]":
            if транспорт:
                итог[транспорт] = порт
            блок, транспорт, порт = True, None, None
            continue
        if голая.startswith("["):
            if транспорт:
                итог[транспорт] = порт
            блок, транспорт, порт = False, None, None
            continue
        if блок and голая.startswith("transport"):
            транспорт = голая.split("=", 1)[1].strip().strip('"')
        if блок and голая.startswith("port"):
            порт = голая.split("=", 1)[1].strip()
    if транспорт:
        итог[транспорт] = порт
    return итог


# --- включение WEB --------------------------------------------------------

def test_секция_server_переживает_включение(tmp_path):
    текст, ответ = включить_web(ДО_WEB, tmp_path)
    assert ответ.returncode == 0, ответ.stderr
    assert "[server]" in текст, "заголовок [server] удалён:\n" + текст


def test_соседние_ключи_остались_в_своей_секции(tmp_path):
    """Тот самый дефект: метрики уезжали в [general.modes] и выключались."""
    текст, _ = включить_web(ДО_WEB, tmp_path)
    строки = [с.strip() for с in текст.splitlines()]
    начало = строки.index("[server]")
    следующая = next(
        i for i in range(начало + 1, len(строки))
        if строки[i].startswith("[")
    )
    внутри = строки[начало:следующая]
    assert any(с.startswith("metrics_listen") for с in внутри), (
        "metrics_listen ушёл из [server] — движок его проигнорирует:\n" + текст
    )
    assert any(с.startswith("metrics_whitelist") for с in внутри), текст


def test_ключ_port_из_секции_server_убран(tmp_path):
    """Его отменяют явные listener-ы, ради этого правка и делается."""
    текст, _ = включить_web(ДО_WEB, tmp_path)
    строки = [с.strip() for с in текст.splitlines()]
    начало = строки.index("[server]")
    следующая = next(
        i for i in range(начало + 1, len(строки)) if строки[i].startswith("[")
    )
    assert not any(с.startswith("port") for с in строки[начало:следующая]), текст


def test_слушатели_на_разных_портах(tmp_path):
    текст, _ = включить_web(ДО_WEB, tmp_path)
    найдено = слушатели(текст)
    assert найдено.get("mtproxy") == "8444", найдено
    assert найдено.get("web") == "15080", найдено
    assert найдено["mtproxy"] != найдено["web"], "оба на одном порту"


def test_чужие_секции_не_тронуты(tmp_path):
    текст, _ = включить_web(ДО_WEB, tmp_path)
    for кусок in ('[server.api]', 'listen = "127.0.0.1:9091"',
                  '[censorship]', 'tls_domain = "adk.example.com"',
                  '[general.modes]', 'classic = false'):
        assert кусок in текст, f"{кусок} потерян:\n{текст}"


# --- починка после чужого установщика -------------------------------------

def test_порт_web_слушателя_восстановлен(tmp_path):
    текст, ответ = починить(СЛОМАННЫЙ, tmp_path)
    assert ответ.returncode == 0, ответ.stderr
    assert слушатели(текст).get("web") == "15080", текст


def test_порт_mtproxy_слушателя_не_тронут(tmp_path):
    """Обратная сторона: наивная правка «всем нужный порт» сломала бы FakeTLS."""
    текст, _ = починить(СЛОМАННЫЙ, tmp_path)
    assert слушатели(текст).get("mtproxy") == "8444", текст


def test_секция_api_не_тронута(tmp_path):
    """У [server.api] свой ключ listen — правка по имени ключа задела бы его."""
    текст, _ = починить(СЛОМАННЫЙ, tmp_path)
    assert 'listen = "127.0.0.1:9091"' in текст, текст
    assert "[server.api]" in текст, текст


def test_исправный_файл_не_переписывается(tmp_path):
    """Лишняя перезапись чужого конфига — лишний шанс его испортить."""
    целый = СЛОМАННЫЙ.replace(
        'port = 8444\ntransport = "web"', 'port = 15080\ntransport = "web"'
    )
    было = hashlib.sha256(целый.encode()).hexdigest()
    текст, ответ = починить(целый, tmp_path)
    assert ответ.returncode == 0
    assert hashlib.sha256(текст.encode()).hexdigest() == было, (
        "файл переписан, хотя чинить было нечего"
    )


def test_конфиг_без_слушателей_не_трогается(tmp_path):
    """WEB не включён — чинить нечего, и лезть в чужой файл незачем."""
    простой = '[server]\nport = 8444\n'
    текст, ответ = починить(простой, tmp_path)
    assert ответ.returncode == 0
    assert текст == простой, текст


def test_починка_переживает_повтор(tmp_path):
    """Второй прогон подряд обязан ничего не менять."""
    первый, _ = починить(СЛОМАННЫЙ, tmp_path)
    второй, ответ = починить(первый, tmp_path)
    assert ответ.returncode == 0
    assert второй == первый, второй


def test_после_включения_починка_ничего_не_находит(tmp_path):
    """Сквозная: то, что пишем сами, не должно требовать немедленной починки."""
    текст, _ = включить_web(ДО_WEB, tmp_path)
    после, ответ = починить(текст, tmp_path)
    assert ответ.returncode == 0
    assert после == текст, "свежезаписанный конфиг признан сломанным"
