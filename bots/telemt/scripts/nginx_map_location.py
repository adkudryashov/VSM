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
MARKER = "location /telemt-map"


def strip_comments(text: str) -> str:
    """Убирает комментарии, чтобы '#' с фигурной скобкой не сбивал счётчик."""
    return re.sub(r"#[^\n]*", "", text)


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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--domain", required=True)
    ap.add_argument("--map-dir", required=True)
    args = ap.parse_args()

    target = pick_target(args.domain)
    if target is None:
        print(f"не найден server-блок с server_name {args.domain}", file=sys.stderr)
        return 1

    _ssl, path, start, end, text = target
    block = text[start:end + 1]

    if MARKER in block:
        print(f"location уже настроен в {path} — ничего не меняю")
        return 0

    snippet = (
        f"\n    {MARKER} {{\n"
        f"        alias {args.map_dir.rstrip('/')}/;\n"
        f"        try_files map.html =404;\n"
        f'        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";\n'
        f"    }}\n"
    )
    updated = text[:end] + snippet + text[end:]

    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    backup = path.with_name(path.name + f".bak-{stamp}")
    shutil.copy2(path, backup)

    path.write_text(updated, encoding="utf-8")

    check = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
    if check.returncode != 0:
        shutil.copy2(backup, path)
        print("nginx -t не прошёл, файл восстановлен из бэкапа:", file=sys.stderr)
        print(check.stderr.strip(), file=sys.stderr)
        return 1

    print(f"location добавлен в {path} (бэкап: {backup.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
