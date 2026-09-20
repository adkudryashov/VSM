"""
Автопродление сертификата: правка конфигов.

ЗАЧЕМ. Сертификат живёт 90 дней, и пока он действует, всё выглядит исправным.
VSM выпускает его способом standalone — certbot сам поднимает сервер на порту
80, ради чего пункт меню гасит nginx. Выпуск так проходит, а продление НЕТ:
при автоматическом продлении nginx никто не останавливает, порт занят им же.
Замерено на стенде 20.09.2026 — «Could not bind TCP port 80».

Здесь проверяется то, чем это чинится: врезка пути проверки владения доменом в
чужой конфиг nginx и перевод renewal-файлов на webroot. Обе правки идут от
root по файлам, которые VSM не принадлежат, поэтому у каждой проверки есть
обратная сторона: чего трогать НЕ должны.
"""
import subprocess
import textwrap
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
БИБЛИОТЕКА = КОРЕНЬ / "lib" / "cert_renew.sh"

pytestmark = pytest.mark.skipif(
    not БИБЛИОТЕКА.is_file(), reason="lib/cert_renew.sh не найдена"
)


def bash(скрипт):
    """Выполняет кусок bash с подключённой библиотекой и возвращает результат."""
    полный = f'. "{БИБЛИОТЕКА.as_posix()}"\n{textwrap.dedent(скрипт)}'
    return subprocess.run(
        ["bash", "-c", полный],
        capture_output=True, text=True, encoding="utf-8",
    )


ВХОД_С_ПЕРЕНАПРАВЛЕНИЕМ = """\
server {
    listen 80;
    server_name adkrw.example.com adkrww.example.com;
    return 301 https://$host$request_uri;
}
"""

ВХОД_БЕЗ_ПЕРЕНАПРАВЛЕНИЯ = """\
server {
    listen 80;
    server_name adkrw.example.com;
    location / { root /var/www/html; }
}
"""


def врезать(текст, tmp_path):
    вход = tmp_path / "vhost"
    вход.write_text(текст, encoding="utf-8")
    готово = bash(f'cert_acme_insert < "{вход.as_posix()}"')
    return готово


# --- врезка пути проверки --------------------------------------------------

def test_путь_проверки_появляется(tmp_path):
    готово = врезать(ВХОД_С_ПЕРЕНАПРАВЛЕНИЕМ, tmp_path)
    assert готово.returncode == 0, готово.stderr
    assert "location ^~ /.well-known/acme-challenge/" in готово.stdout


def test_перенаправление_переезжает_внутрь_location(tmp_path):
    """
    Главная тонкость. return на уровне server выполняется РАНЬШЕ выбора
    location и перехватывает в том числе путь проверки: замерено 20.09.2026 —
    Let's Encrypt получал 301 вместо файла при совершенно верном на вид
    конфиге. Значит перенаправление обязано оказаться внутри location /.
    """
    готово = врезать(ВХОД_С_ПЕРЕНАПРАВЛЕНИЕМ, tmp_path)
    строки = [с.strip() for с in готово.stdout.splitlines() if с.strip()]

    i_acme = next(i for i, с in enumerate(строки) if "acme-challenge/" in с and с.startswith("location"))
    i_loc = next(i for i, с in enumerate(строки) if с == "location / {")
    i_ret = next(i for i, с in enumerate(строки) if с.startswith("return 301"))

    assert i_acme < i_loc, "путь проверки должен стоять до перенаправления"
    assert i_loc < i_ret, "перенаправление должно оказаться ВНУТРИ location /"


def test_перенаправления_на_уровне_server_не_осталось(tmp_path):
    готово = врезать(ВХОД_С_ПЕРЕНАПРАВЛЕНИЕМ, tmp_path)
    # Единственный return — тот, что внутри location, с отступом в 8 пробелов
    # или больше. Строка «    return 301» (4 пробела) означала бы, что он
    # остался на уровне server.
    возвраты = [с for с in готово.stdout.splitlines() if с.lstrip().startswith("return 30")]
    assert len(возвраты) == 1
    assert len(возвраты[0]) - len(возвраты[0].lstrip()) >= 8


def test_конфиг_без_перенаправления_не_ломается(tmp_path):
    """Обратная сторона: если переносить нечего, ничего и не переносим."""
    готово = врезать(ВХОД_БЕЗ_ПЕРЕНАПРАВЛЕНИЯ, tmp_path)
    assert готово.returncode == 0, готово.stderr
    assert "location ^~ /.well-known/acme-challenge/" in готово.stdout
    assert "location / { root /var/www/html; }" in готово.stdout


def test_повторная_врезка_ничего_не_добавляет(tmp_path):
    """
    Второй такой же location — это отказ nginx собрать конфиг целиком, то есть
    падение всего сервера от повторного запуска починки. А починку запускает
    сверка, то есть раз в час.
    """
    первый = врезать(ВХОД_С_ПЕРЕНАПРАВЛЕНИЕМ, tmp_path)
    второй = врезать(первый.stdout, tmp_path)
    assert второй.stdout == первый.stdout
    assert второй.stdout.count("acme-challenge/") == 1


def test_чужой_порт_не_считается_восьмидесятым(tmp_path):
    """
    Контрольный случай. listen 8080 и listen 8000 начинаются с «80», и правка
    по подстроке врезала бы путь проверки в чужой блок, оставив продление
    сломанным — молча, потому что конфиг при этом собирается.
    """
    готово = врезать("server {\n    listen 8080;\n    server_name x;\n}\n", tmp_path)
    assert готово.returncode == 1
    assert "acme-challenge" not in готово.stdout


def test_скобка_в_комментарии_не_сдвигает_границы(tmp_path):
    текст = "server {\n    # закрывающая } в комментарии\n    listen 80;\n    server_name x;\n}\n"
    готово = врезать(текст, tmp_path)
    assert готово.returncode == 0, готово.stderr
    assert "acme-challenge/" in готово.stdout


# --- выбор конфига ---------------------------------------------------------

def test_два_кандидата_это_отказ(tmp_path):
    """
    Лучше сказать «не разобрался», чем уверенно врезать не в тот файл: на
    установке с чужим конфигом по умолчанию кандидатов два, и ошибка здесь
    оставляет продление сломанным, ничем этого не показав.
    """
    d = tmp_path / "sites"
    d.mkdir()
    for имя in ("a", "b"):
        (d / имя).write_text("server {\n    listen 80;\n}\n", encoding="utf-8")
    готово = bash(f'CERT_NGINX_DIRS="{d.as_posix()}"; cert_acme_vhost && echo НАШЁЛ || echo ОТКАЗ')
    assert "ОТКАЗ" in готово.stdout


def test_единственный_кандидат_находится(tmp_path):
    d = tmp_path / "sites"
    d.mkdir()
    (d / "80.conf").write_text("server {\n    listen 80;\n}\n", encoding="utf-8")
    (d / "прочее").write_text("server {\n    listen 443 ssl;\n}\n", encoding="utf-8")
    готово = bash(f'CERT_NGINX_DIRS="{d.as_posix()}"; cert_acme_vhost')
    assert готово.stdout.strip().endswith("80.conf")


# --- renewal-файлы ---------------------------------------------------------

STANDALONE = "version = 4.0.0\n[renewalparams]\nauthenticator = standalone\nkey_type = ecdsa\n"
ЧЕРЕЗ_DNS = "version = 4.0.0\n[renewalparams]\nauthenticator = dns-cloudflare\nkey_type = ecdsa\n"


def test_standalone_переводится_на_webroot(tmp_path):
    (tmp_path / "site.conf").write_text(STANDALONE, encoding="utf-8")
    готово = bash(
        f'CERT_RENEWAL_DIR="{tmp_path.as_posix()}"; CERT_BACKUP_DIR="{(tmp_path / "копии").as_posix()}"; '
        'cert_renewal_webroot_ensure'
    )
    assert готово.returncode == 0, готово.stderr
    стало = (tmp_path / "site.conf").read_text(encoding="utf-8")
    assert "authenticator = webroot" in стало
    assert "webroot_path = /var/www/html," in стало


def test_проверка_через_dns_остаётся_нетронутой(tmp_path):
    """
    Обратная сторона, и важная. Кто проверяет владение доменом через DNS,
    настроил это сам, порт 80 ему не нужен, и его продление работает.
    Переписать такую установку значило бы сломать исправное ради своего
    представления о правильном.
    """
    (tmp_path / "site.conf").write_text(ЧЕРЕЗ_DNS, encoding="utf-8")
    bash(
        f'CERT_RENEWAL_DIR="{tmp_path.as_posix()}"; CERT_BACKUP_DIR="{(tmp_path / "копии").as_posix()}"; '
        'cert_renewal_webroot_ensure'
    )
    assert (tmp_path / "site.conf").read_text(encoding="utf-8") == ЧЕРЕЗ_DNS


def test_повторный_перевод_не_дублирует_путь(tmp_path):
    (tmp_path / "site.conf").write_text(STANDALONE, encoding="utf-8")
    команда = (
        f'CERT_RENEWAL_DIR="{tmp_path.as_posix()}"; CERT_BACKUP_DIR="{(tmp_path / "копии").as_posix()}"; '
        'cert_renewal_webroot_ensure; cert_renewal_webroot_ensure'
    )
    bash(команда)
    стало = (tmp_path / "site.conf").read_text(encoding="utf-8")
    assert стало.count("webroot_path") == 1


def test_копия_снимается_до_правки(tmp_path):
    """Правка идёт от root по чужому файлу — вернуть его должно быть чем."""
    копии = tmp_path / "копии"
    (tmp_path / "site.conf").write_text(STANDALONE, encoding="utf-8")
    bash(
        f'CERT_RENEWAL_DIR="{tmp_path.as_posix()}"; CERT_BACKUP_DIR="{копии.as_posix()}"; '
        'cert_renewal_webroot_ensure'
    )
    сохранённое = копии / "site.conf.before-webroot"
    assert сохранённое.is_file()
    assert сохранённое.read_text(encoding="utf-8") == STANDALONE
