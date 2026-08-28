"""
Чтение вердикта доступности, который считает MTProxyL.

ЗАЧЕМ. Проверка «доступность из России» стоит российских зондов у вашего
сервера, и мерить одно и то же дважды — значит платить заметностью за
дубликат. MTProxyL с версии 1.4.8 ведёт эту проверку сам по своему таймеру, и
её результат одинаково нужен трём потребителям: его панели, его меню и нашему
боту. Поэтому бот не меряет, а читает — ровно так же поступает алерт-бот
автора.

    одно измерение (таймер MTProxyL)
       ├── панель MTProxyL   — карточка доступности
       ├── меню «Дополнения» — строка состояния
       └── наш сторож        — тревоги, гистерезис, светофор, карточка

ЧТЕНИЕ НИЧЕГО НЕ СТОИТ: это локальный файл, наружу не уходит ни один пакет.
Поэтому опрашивать его можно хоть каждую минуту, а новый вердикт узнаётся по
метке checked_at — она ставится в момент измерения, поэтому одна и та же метка
означает один и тот же вердикт, даже если файл перезаписали.

ЕСЛИ MTProxyL НЕ УСТАНОВЛЕН — а это обычная установка VSM — источника нет, и
сторож меряет сам, как раньше. Развилка в monitor._maybe_check_ru.

МЫ ЗАВИСИМ ОТ ЧУЖОГО ФОРМАТА, и это осознанно. Защита одна: всё, что не удалось
прочитать или разобрать, считается «данных нет», а не поводом для тревоги.
Ложная тревога о падении доступности из-за того, что автор переименовал поле, —
худший исход из возможных.
"""

import json
import logging
import os
from datetime import datetime, timezone
from typing import Optional

# Путь задан автором и одинаков на всех установках MTProxyL.
VERDICT_PATH = "/opt/mtproxyl/availability/last.json"


def available(path: str = VERDICT_PATH) -> bool:
    """Есть ли вообще чужой источник. Не «установлен ли MTProxyL», а именно
    «можем ли мы прочитать его вердикт»: бот может работать не от root."""
    return os.access(path, os.R_OK)


def _epoch(value: str) -> float:
    """ISO-время из вердикта в секунды. Ноль — не разобрали."""
    if not value:
        return 0.0
    try:
        # Замена «Z» нужна для Python до 3.11: там fromisoformat её не понимает.
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return 0.0
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def read_verdict(path: str = VERDICT_PATH) -> Optional[dict]:
    """
    Приводит чужой вердикт к тому же виду, что отдаёт globalping.analyze().

    None означает «данных нет»: файла нет, он битый, или MTProxyL записал в него
    свою ошибку вместо измерения. Во всех трёх случаях судить о доступности
    нечего, и состояние тревоги трогать нельзя.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except Exception as exc:
        logging.info("Сторож: вердикт MTProxyL не прочитан: %s", exc)
        return None

    if not isinstance(data, dict):
        return None

    # Непустое error означает, что измерения не было: MTProxyL пишет сюда
    # причину, по которой не смог проверить. Это не ноль процентов.
    failure = str(data.get("error") or "").strip()
    if failure:
        return {"error": failure, "checked_at": _epoch(str(data.get("checked_at") or "")),
                "source": "mtproxyl"}

    try:
        total = int(data.get("total_probes") or 0)
        success = int(data.get("success_probes") or 0)
        pct = float(data.get("percentage") or 0.0)
    except (TypeError, ValueError):
        return None

    if total <= 0:
        # Ни один зонд не взялся за проверку. Считать это нулём процентов
        # нельзя — прокси тут ни при чём.
        return None

    reasons: dict = {}
    probes: list = []
    for probe in data.get("probes") or []:
        if not isinstance(probe, dict):
            continue
        ok = bool(probe.get("tls_success"))
        reason = "" if ok else (str(probe.get("error") or "").strip()
                                or "соединение не установлено")
        if not ok:
            reasons[reason] = reasons.get(reason, 0) + 1
        probes.append({
            "ok": ok,
            "city": str(probe.get("city") or ""),
            "network": str(probe.get("network") or ""),
            "asn": probe.get("asn") or 0,
            "error": reason,
        })

    return {
        "success": success,
        "total": total,
        "pct": pct,
        "reasons": reasons,
        # Разбор по зондам: какой провайдер и город доходят, а какие нет.
        # Именно это отвечает на вопрос «у кого именно не работает», на который
        # общий процент не отвечает никогда.
        "probes": probes,
        "checked_at": _epoch(str(data.get("checked_at") or "")),
        "target": str(data.get("target") or ""),
        "source": "mtproxyl",
        # Зонды потратил MTProxyL по своей квоте — нашему реестру списывать
        # нечего, и показывать наш остаток при этом источнике незачем.
        "charged": 0,
    }


# Путь задан автором и одинаков на всех установках MTProxyL.
SETTINGS_PATH = "/opt/mtproxyl/settings.conf"


def own_probes_per_hour(path: str = SETTINGS_PATH) -> float:
    """
    Сколько раз в час МЫ САМИ стучимся в свой прокси проверкой доступности.

    ЗАЧЕМ. Зонд Globalping приходит на порт telemt обычным TLS-клиентом, а не
    клиентом MTProto: маскировка его не узнаёт, отдаёт на запасную страницу и
    засчитывает в `tls_handshake_bad_client`. То есть часть «чужих» соединений
    создаём мы сами своим же наблюдением, и без этой поправки сводка выдаёт их
    за посторонних.

    ЗАМЕРЕНО 28.08.2026: за 11 часов работы telemt через маску прошло 710
    HTTP-запросов, из них 440 с `User-Agent: globalping probe` — при настройке
    20 зондов каждые 30 минут, то есть ровно 40 в час. Совпадение расчёта с
    журналом nginx и есть подтверждение, что считаем то самое.

    Возвращает ноль, когда источника нет: MTProxyL не установлен, проверка
    выключена, файл нечитаем или в нём чепуха. Ноль означает «не знаем», и
    сводка тогда просто не показывает эту составляющую — врать поправкой,
    взятой из воздуха, хуже, чем не поправлять вовсе.
    """
    values: dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, raw = line.partition("=")
                values[key.strip()] = raw.strip().strip("'\"")
    except FileNotFoundError:
        return 0.0
    except Exception as exc:
        logging.info("Сторож: настройки MTProxyL не прочитаны: %s", exc)
        return 0.0

    if values.get("AVAILABILITY_ENABLED", "").lower() != "true":
        return 0.0
    try:
        probes = int(values.get("AVAILABILITY_PROBES") or 0)
        interval_min = float(values.get("AVAILABILITY_INTERVAL") or 0)
    except (TypeError, ValueError):
        return 0.0
    if probes <= 0 or interval_min <= 0:
        return 0.0
    return probes * 60.0 / interval_min
