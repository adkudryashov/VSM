#!/usr/bin/env python3
"""
Подключает отдачу карты telemt-бота к существующему vhost nginx.

Ищет server-блок с нужным server_name, вставляет в него location /telemt-map
и проверяет конфиг через `nginx -t`. Если проверка не прошла — возвращает
файл из бэкапа, чтобы не оставить nginx в нерабочем состоянии.

Скрипт идемпотентен: если location уже есть, ничего не делает.
"""

import argparse
import datetime
import re
import shutil
import subprocess
import sys
from pathlib import Path

SEARCH_DIRS = ["/etc/nginx/sites-enabled", "/etc/nginx/conf.d"]

# Маркеры вместо поиска по тексту location: по ним блок и находится, и
# заменяется, и снимается. Раньше признаком служила строка "location
# /telemt-map" — то есть путь был захардкожен и одинаков у всех установок,
# а лежит он в публичном репозитории. Любой, кто знает домен (а домен виден
# из сертификата и из журналов Certificate Transparency), открывал карту со
# списком IP всех пользователей прокси одним GET, без пароля.
BEGIN = "# >>> VSM telemt-map — не редактируй вручную"
END = "# <<< VSM telemt-map"

# Бэкап кладём ВНЕ каталогов, которые nginx подключает.
#
# Раньше копия писалась рядом с оригиналом как "<имя>.bak-<дата>", а
# nginx.conf в Ubuntu включает sites-enabled/* БЕЗ фильтра по расширению.
# Копия немедленно подхватывалась как ещё один конфиг: дублирующийся
# server_name (в мягком случае карта отдаёт вечный 404 при рапорте об успехе)
# или "duplicate default server" — тогда nginx не стартует, а вместе с ним по
# Requires=nginx.service ложится telemt. И копии копились при каждом запуске.
BACKUP_DIR = Path("/var/backups/vsm/nginx")


def strip_comments(text: str) -> str:
    """Гасит комментарии, чтобы '#' с фигурной скобкой не сбивал счётчик скобок.

    Заменяем пробелами, а НЕ удаляем: границы server-блоков считаются по этой
    копии, а применяются срезом к оригиналу. Удаление меняет длину строки, и
    все индексы после первого же комментария уезжают — вставка попадает не в
    ту позицию, вплоть до середины чужой директивы. В типовом vhost под certbot
    комментарии есть всегда («# managed by Certbot»), а маркеры этого скрипта
    сами являются комментариями, так что расхождение накапливалось бы с каждым
    повторным запуском.
    """
    return re.sub(r"#[^\n]*", lambda m: " " * len(m.group(0)), text)


def find_server_blocks(text: str):
    """Возвращает список (start, end) — границы каждого server-блока."""
    clean = strip_comments(text)
    blocks = []
    for m in re.finditer(r"\bserver\s*\{", clean):
        depth, i = 0, m.end() - 1
        while i < len(clean):
            if clean[i] == "{":
                depth += 1
            elif clean[i] == "}":
                depth -= 1
                if depth == 0:
                    blocks.append((m.start(), i))
                    break
            i += 1
    return blocks


def server_names(block: str):
    m = re.search(r"\bserver_name\s+([^;]+);", block)
    return m.group(1).split() if m else []


def domain_matches(names, domain: str) -> bool:
    for n in names:
        if n == domain:
            return True
        if n.startswith("*.") and domain.endswith(n[1:]):
            return True
    return False


def pick_target(domain: str):
    """Ищет подходящий блок. Предпочитает тот, что слушает 443."""
    candidates = []
    for d in SEARCH_DIRS:
        p = Path(d)
        if not p.is_dir():
            continue
        for f in sorted(p.iterdir()):
            if not f.is_file() and not f.is_symlink():
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for start, end in find_server_blocks(text):
                block = text[start:end + 1]
                if not domain_matches(server_names(block), domain):
                    continue
                ssl = bool(re.search(r"\blisten\s+[^;]*443", block))
                candidates.append((ssl, f.resolve(), start, end, text))
    if not candidates:
        return None
    candidates.sort(key=lambda c: not c[0])  # сначала ssl
    return candidates[0]


def strip_block(text: str) -> str:
    """Убирает прежний блок VSM целиком, вместе с маркерами и отступом.

    Отступ и перевод строки перед BEGIN тоже съедаем: иначе после каждого
    повторного применения в файле копился бы пустой отступ.
    """
    # Замена на пустую строку, а не на "\n": шаблон съедает и перевод строки
    # ПЕРЕД блоком, и перевод ПОСЛЕ него, а текст левее уже заканчивается
    # переводом — блок всегда вставляется на границе строки. Возврат "\n"
    # оставлял лишнюю пустую строку, и она копилась с каждым циклом
    # вставки-снятия. Поймано тестом на стенде, вычиткой видно не было.
    return re.sub(
        r"\n?[ \t]*" + re.escape(BEGIN) + r".*?" + re.escape(END) + r"[ \t]*\n?",
        "",
        text,
        flags=re.S,
    )


def pick_block_in_text(text: str, domain: str):
    """Границы подходящего server-блока в готовом тексте, ssl — в приоритете.

    Отдельная функция, потому что после снятия прежнего блока границы
    сдвигаются и искать надо заново. Приоритет ssl обязателен: в типовом vhost
    «80 → редирект на 443» первым сверху лежит блок порта 80, и попасть туда
    значило бы отдавать карту по http, мимо TLS.
    """
    found = []
    for start, end in find_server_blocks(text):
        block = text[start:end + 1]
        if not domain_matches(server_names(block), domain):
            continue
        ssl = bool(re.search(r"\blisten\s+[^;]*443", block))
        found.append((ssl, start, end))
    if not found:
        return None
    found.sort(key=lambda c: not c[0])
    return found[0]


def write_checked(path: Path, updated: str, what: str) -> int:
    """Пишет конфиг с бэкапом вне include-путей и откатом по nginx -t."""
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    backup = BACKUP_DIR / f"{path.name}.{stamp}"
    shutil.copy2(path, backup)

    path.write_text(updated, encoding="utf-8")

    check = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if check.returncode != 0:
        shutil.copy2(backup, path)
        print("nginx -t не прошёл, файл восстановлен из бэкапа:", file=sys.stderr)
        print(check.stderr.strip(), file=sys.stderr)
        return 1

    print(f"{what} в {path} (бэкап: {backup})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    # --domain не обязателен при --remove: блок ищется по маркеру во всех
    # конфигах, и снять его нужно даже тогда, когда домен уже забыт.
    ap.add_argument("--domain")
    ap.add_argument("--map-dir")
    ap.add_argument("--path", help="секретный префикс пути, без слэшей")
    ap.add_argument("--remove", action="store_true", help="снять блок и выйти")
    ap.add_argument("--mask-domain", help="домен self-SNI маскировки: на него вешать нельзя")
    args = ap.parse_args()

    # На домен маскировки карту вешать нельзя ни при каких условиях.
    #
    # Маска копирует у vhost панели root и параметры TLS, но НЕ копирует
    # location-блоки. Значит, тот же URL на 443 вернул бы 200, а через порт
    # telemt — 404. Это готовый однозапросный признак: два ответа на один
    # адрес при одном сертификате бывают только у проксирования.
    if args.mask_domain and args.domain == args.mask_domain:
        print(
            f"нельзя вешать карту на {args.domain}: это цель self-SNI маскировки, "
            "и location на нём делает порт telemt отличимым от сайта",
            file=sys.stderr,
        )
        return 1

    # Снятие ищет блок по маркеру во ВСЕХ конфигах, а не только в vhost
    # текущего домена: домен карты мог смениться с тех пор, как блок ставили,
    # и привязка к нему оставила бы старый блок работать вечно.
    if args.remove:
        rc, removed = 0, 0
        for d in SEARCH_DIRS:
            p = Path(d)
            if not p.is_dir():
                continue
            for f in sorted(p.iterdir()):
                if not (f.is_file() or f.is_symlink()):
                    continue
                try:
                    t = f.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                if BEGIN not in t:
                    continue
                removed += 1
                rc |= write_checked(f.resolve(), strip_block(t), "блок карты снят")
        if removed == 0:
            print("блок карты нигде не найден — снимать нечего")
        return rc

    if not args.domain or not args.map_dir or not args.path:
        print("для установки нужны --domain, --map-dir и --path", file=sys.stderr)
        return 1
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.path):
        print(f"недопустимый префикс пути: {args.path!r}", file=sys.stderr)
        return 1

    target = pick_target(args.domain)
    if target is None:
        print(f"не найден server-блок с server_name {args.domain}", file=sys.stderr)
        return 1
    _ssl, path, _start, _end, text = target

    # Сначала снимаем прежний блок: путь мог смениться, и два location с
    # разными префиксами оставили бы старый адрес рабочим.
    cleaned = strip_block(text)
    # После чистки границы сдвинулись — ищем блок заново, и снова с
    # приоритетом ssl, иначе карта уедет в редирект с 80.
    again = pick_block_in_text(cleaned, args.domain)
    if again is None:
        print("после снятия прежнего блока server-блок не найден", file=sys.stderr)
        return 1
    end = again[2]

    # Referrer-Policy обязателен, и это не украшение.
    #
    # Секретный префикс в /{args.path}/ — ЕДИНСТВЕННАЯ защита карты: пароля у
    # неё нет. А страница подгружает тайлы подложки с чужого CDN, и браузер
    # прикладывает к каждому такому запросу заголовок Referer с полным адресом
    # страницы. То есть без этой строки секрет уезжает наружу при каждом
    # открытии карты — вместе со списком IP всех пользователей за ним.
    # Замерено: до этой правки страница ходила на четыре CDN и тайловый сервис.
    #
    # try_files отдаёт сначала сам файл и лишь потом карту: рядом с map.html
    # лежит каталог assets с локальными копиями leaflet (utils/mapassets.py).
    # Прежнее "try_files map.html" возвращало карту на ЛЮБОЙ адрес внутри
    # префикса, и библиотеки получить было нельзя. Запасной путь на map.html
    # сохранён — на него опирается кнопка бота, дописывающая к адресу хвост.
    #
    # "=404" в конце обязателен, и это не перестраховка: ПОСЛЕДНИЙ параметр
    # try_files nginx понимает не как файл, а как URI для внутреннего
    # перенаправления. Без него "try_files $uri map.html" отдавал 404 на саму
    # карту, отдавая при этом библиотеки, — поймано проверкой на стенде, по
    # чтению конфига не видно вовсе.
    snippet = (
        f"\n    {BEGIN}\n"
        f"    location /{args.path}/ {{\n"
        f"        alias {args.map_dir.rstrip('/')}/;\n"
        f"        try_files $uri map.html =404;\n"
        f'        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";\n'
        f'        add_header X-Robots-Tag "noindex, nofollow" always;\n'
        f'        add_header Referrer-Policy "no-referrer" always;\n'
        f"    }}\n"
        f"    {END}\n"
    )
    updated = cleaned[:end] + snippet + cleaned[end:]
    return write_checked(path, updated, "блок карты добавлен")


if __name__ == "__main__":
    sys.exit(main())
