"""
Мост к сверке с реестром решений VSM: bash считает, бот доставляет.

ПОЧЕМУ РЕЕСТР ОСТАЛСЯ В BASH. Он читает конфиги чужих компонентов, состояние
служб и права sudoers — всё то, чем VSM занимается на bash с первого дня. Его
же запускают из меню, где никакого Python нет. Переписывать его сюда значило бы
завести вторую реализацию одной сверки, а две реализации однажды разойдутся —
это ровно тот класс ошибок, ради которого реестр и появился.

Бот здесь делает одно: запускает сверку по расписанию и приносит результат
владельцу тем же каналом, что и тревоги.

СВЕРКА ЧИНИТ. Позиции класса «незаметность и безопасность» возвращаются молча,
и о починке сообщается постфактум — так решил владелец, и цена бездействия там
действительно выше цены неожиданности. Всё остальное только показывается.
"""

import asyncio
import json
import logging
from pathlib import Path

# bots/telemt/watchdog/drift.py → корень репозитория на четыре уровня выше.
SCRIPT = Path(__file__).resolve().parents[3] / "checks" / "drift.sh"


def available() -> bool:
    return SCRIPT.is_file()


async def run(fix: bool = True, timeout: float = 180.0) -> dict | None:
    """
    Прогоняет сверку и возвращает разобранный отчёт. None — не получилось.

    Код возврата 1 у сверки означает «есть расхождения», а не «ошибка запуска»,
    поэтому по нему не судим: смотрим, разобрался ли JSON.
    """
    if not available():
        return None

    args = ["bash", str(SCRIPT), "--json"]
    if not fix:
        args.append("--dry-run")

    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        logging.warning("Сверка с реестром не завершилась за %s с", timeout)
        return None
    except Exception as exc:
        logging.warning("Сверка с реестром не запустилась: %s", exc)
        return None

    try:
        return json.loads(out.decode("utf-8", "replace"))
    except Exception as exc:
        tail = (err or b"").decode("utf-8", "replace").strip()[:200]
        logging.warning("Сверка с реестром вернула неразборчивое (%s): %s", exc, tail)
        return None


def split(report: dict) -> tuple:
    """
    Делит отчёт на то, что уже вернули, и то, что ждёт человека.

    Позиции «нет компонента», «исключено» и «запомнено» в оба списка не
    попадают: это не события, а объяснения, почему события не было.
    """
    fixed, pending = [], []
    for item in (report or {}).get("items") or []:
        status = item.get("status")
        if status == "починено":
            fixed.append(item)
        elif status in ("расхождение", "починить не удалось"):
            pending.append(item)
    return fixed, pending


def signature(items: list) -> str:
    """
    Отпечаток набора нерешённых расхождений.

    Нужен, чтобы отличить «появилось новое» от «висит то же самое»: первое
    сообщается сразу, второе напоминает о себе по расписанию, как и тревоги.
    """
    return ",".join(sorted(f"{i.get('id')}:{i.get('status')}" for i in items))
