"""
Локальные копии библиотек для карты подключений.

ЗАЧЕМ. Карта закрыта единственной защитой — секретным префиксом пути, который
VSM генерирует при установке (stacks/bots.sh). Никакого пароля у неё нет.
А страница, которую folium собирает по умолчанию, подгружает тринадцать файлов
с четырёх чужих CDN: jsdelivr, cdnjs (Cloudflare), code.jquery.com,
netdna.bootstrapcdn.com. Отсюда две беды сразу.

ПЕРВАЯ: браузер шлёт каждому из них заголовок Referer с полным адресом
страницы — то есть отдаёт им тот самый секретный префикс, на котором всё
держится. Это чинится заголовком Referrer-Policy в nginx (см.
scripts/nginx_map_location.py), и он поставлен.

ВТОРАЯ, которую заголовком не закрыть: десять чужих скриптов исполняются на
странице, где перечислены IP всех пользователей прокси, и ни у одного нет
integrity=. Владельцу CDN — или тому, кто до него доберётся, — достаточно
подменить один файл, чтобы этот список уехал куда угодно. Поэтому файлы
складываются рядом с картой и грузятся оттуда.

ЧТО ОСТАЁТСЯ СНАРУЖИ. Тайлы подложки: их отдаёт CartoDB, и локальная копия
мира здесь невозможна. Владелец выбрал оставить фон осознанно — значит CartoDB
видит адрес смотрящего и то, какие районы он разглядывает. Секретный префикс
к нему больше не уходит, за это отвечает Referrer-Policy.

ПОЧЕМУ ЗАБИРАЕМ ВСЁ, А НЕ ТОЛЬКО НУЖНОЕ. Первая версия выбрасывала библиотеки,
которыми карта на вид не пользуется: bootstrap, jquery, fontawesome,
awesome-markers. В браузере она немедленно легла с «$ is not defined» —
folium строит ВСПЛЫВАЮЩИЕ ПОДПИСИ через jQuery, а в них весь смысл карты: IP,
город, провайдер. Точки при этом рисовались, то есть поломка была тихой.

Отсюда правило: белый список отобранных вручную файлов опасен не тем, что
ошибается сегодня, а тем, что следующее обновление folium добавит библиотеку,
о которой здесь никто не узнает, — и карта сломается так же тихо. Поэтому
локальным становится ВСЁ, что страница тянет с CDN, без разбора. Лишний файл
на диске стоит ничего, упавшая карта — визита владельца раз в неделю впустую.

ПОЧЕМУ ПРАВИМ ТЕКСТ СТРАНИЦЫ, А НЕ ОБЪЕКТЫ FOLIUM. Первая версия переписывала
url у элементов в figure.header и выглядела чище. Но folium собирает заголовок
заново при КАЖДОЙ отрисовке, и следующий же save() возвращал все ссылки на
CDN. Поймано проверкой на стенде: модуль честно докладывал «внешних не
осталось», а в готовом файле стояли все четыре домена. Поэтому здесь правится
то, что реально уедет в браузер, — сам HTML.
"""

import hashlib
import logging
import re
from pathlib import Path
from typing import Tuple

import httpx

ASSETS_DIRNAME = "assets"

# Теги, которые folium ставит в заголовок. Оба вида — с закрывающим </script>
# и самозакрывающийся <link/>.
_SCRIPT = re.compile(r'<script\s+src="(https?://[^"]+)"\s*>\s*</script>', re.I)
_LINK = re.compile(r'<link[^>]*?href="(https?://[^"]+)"[^>]*?/?>', re.I)

# url(...) внутри CSS: leaflet.css ссылается так на images/marker-icon.png,
# без которых на карте не будет самих меток.
_CSS_URL = re.compile(rb"url\(\s*['\"]?([^)'\"]+)['\"]?\s*\)")


def _file_name(url: str) -> str:
    """Имя файла из адреса, очищенное до безопасного в пути."""
    tail = url.split("?", 1)[0].split("#", 1)[0].rsplit("/", 1)[-1]
    return re.sub(r"[^A-Za-z0-9._-]", "_", tail) or "asset"


def _slot(url: str) -> str:
    """
    Подкаталог под один источник: восемь знаков от хэша его каталога.

    Файлы с разных CDN спокойно совпадают именами — all.min.css есть у
    fontawesome и не только у него, — и в общей папке молча затирали бы друг
    друга. Хуже того, CSS ссылается на соседние файлы ОТНОСИТЕЛЬНО себя
    (images/marker-icon.png), так что разложить их плоско нельзя в принципе.
    Свой подкаталог на источник решает оба: имена не сталкиваются, а
    относительные ссылки внутри CSS продолжают вести куда вели.
    """
    base = url.split("?", 1)[0].rsplit("/", 1)[0]
    return hashlib.sha256(base.encode("utf-8")).hexdigest()[:8]


def _fetch(client: httpx.Client, url: str, dest: Path) -> bool:
    """Кладёт файл, если его ещё нет. True — файл на месте."""
    if dest.exists() and dest.stat().st_size > 0:
        return True
    try:
        resp = client.get(url)
        resp.raise_for_status()
    except Exception as exc:
        logging.warning("Карта: не удалось забрать %s (%s)", url, exc)
        return False
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(resp.content)
    except OSError as exc:
        logging.warning("Карта: не удалось сохранить %s (%s)", dest, exc)
        return False
    return True


def _fetch_css_deps(client: httpx.Client, css_url: str, css_path: Path) -> None:
    """
    Дотягивает то, на что ссылается сам CSS: картинки меток и шрифты.

    Без этого leaflet.css стал бы локальным, а marker-icon.png продолжал бы
    ехать с CDN — внешний запрос никуда бы не делся, просто стал незаметнее.
    Абсолютные ссылки пропускаем: ходить по ним вглубь чужих доменов мы не
    подписывались.
    """
    try:
        body = css_path.read_bytes()
    except OSError:
        return
    base = css_url.rsplit("/", 1)[0]
    for raw in set(_CSS_URL.findall(body)):
        rel = raw.decode("utf-8", "replace").strip()
        if not rel or rel.startswith(("data:", "http://", "https://", "//", "#")):
            continue
        rel = rel.split("?", 1)[0].split("#", 1)[0]
        # ../webfonts/x.woff2 → webfonts/x.woff2 внутри assets. Выход за
        # пределы каталога отбрасываем: путь собирается из очищенных частей.
        parts = [p for p in rel.split("/") if p not in ("", ".", "..")]
        if not parts:
            continue
        _fetch(client, f"{base}/{rel}", css_path.parent.joinpath(*parts))


def localize(page: str, map_dir: str, timeout: float = 20.0) -> Tuple[str, int]:
    """
    Возвращает страницу с локальными ссылками и число оставшихся внешних.

    Ноль во втором значении означает, что в заголовке не осталось ни одного
    чужого адреса. Тайлы подложки сюда не входят: они подставляются скриптом
    во время работы карты и остаются внешними по решению владельца.

    Неудачная загрузка не ломает карту: ссылка остаётся внешней, а в журнал
    уходит предупреждение. Карта, которая не открылась, хуже карты, сходившей
    за библиотекой на CDN, — тем более что секретный префикс к ней всё равно
    не уедет, за это отвечает Referrer-Policy.
    """
    assets = Path(map_dir) / ASSETS_DIRNAME
    remote_left = 0

    with httpx.Client(timeout=timeout, follow_redirects=True) as client:

        def handle(match: "re.Match") -> str:
            nonlocal remote_left
            url = match.group(1)
            name = _file_name(url)
            slot = _slot(url)
            local = assets / slot / name
            if not _fetch(client, url, local):
                remote_left += 1
                return match.group(0)
            if local.suffix.lower() == ".css":
                _fetch_css_deps(client, url, local)
            # Ссылка относительная: map.html лежит рядом с assets, а абсолютная
            # сломалась бы при смене секретного префикса.
            return match.group(0).replace(url, f"{ASSETS_DIRNAME}/{slot}/{name}")

        page = _SCRIPT.sub(handle, page)
        page = _LINK.sub(handle, page)

    return page, remote_left
