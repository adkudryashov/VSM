"""
Доступность прокси из России — через публичные зонды Globalping.

ЧТО ЭТО СТОИТ. Каждый прогон просит сервис Globalping подключиться к вашему
прокси с домашних адресов российских провайдеров. Значит: к серверу идёт
внешний трафик по расписанию, а его адрес, порт и домен FakeTLS уходят в
стороннее API. Для сервера, который маскируется, это заметность. Владелец
выбрал её сознательно, поэтому проверка выключена по умолчанию, а умолчания при
включении щадящие — раз в час по 10 зондов.

ЗАЧЕМ ОНА ВСЁ-ТАКИ НУЖНА. Это единственный сигнал про ВХОД: видят ли вас
клиенты. Всё остальное, что умеет сторож, меряет выход — может ли прокси
достучаться до Telegram. Прокси, заблокированный на подходе, снаружи выглядит
идеально здоровым изнутри.

Успехом считается доведённое рукопожатие TLS, а не установленное соединение:
TCP-коннект о FakeTLS не говорит ничего, а фильтрация обычно и выглядит как
сессия, оборванная в середине рукопожатия.
"""

import asyncio
import logging
from typing import Optional

import httpx

API_URL = "https://api.globalping.io/v1"

# Зонды из домашних сетей, а не из дата-центров: провайдерская фильтрация
# ставится именно на абонентском плече, и с серверных площадок её не видно.
EYEBALL_TAG = "eyeball-network"

# Сервисы определения своего внешнего адреса. Список, а не один: любой из них
# бывает недоступен, а неизвестный адрес отключает обе проверки сразу.
IP_SERVICES = (
    "https://api.ipify.org",
    "https://icanhazip.com",
    "https://ifconfig.me/ip",
    "https://ipecho.net/plain",
)


class GlobalpingError(Exception):
    pass


class RateLimited(GlobalpingError):
    """Отдельный тип: вызывающий обязан перестать тратить кредиты, а не повторять."""


async def public_ip(timeout: float = 6.0) -> str:
    """Внешний адрес сервера. Пустая строка, если не удалось узнать."""
    async with httpx.AsyncClient(timeout=timeout) as client:
        for url in IP_SERVICES:
            try:
                resp = await client.get(url)
                if resp.status_code != 200:
                    continue
                value = resp.text.strip()
                # Грубая проверка формы: сервис под ошибкой возвращает HTML,
                # и без неё в «адрес сервера» попала бы страница целиком.
                if value and len(value) <= 45 and " " not in value and "<" not in value:
                    return value
            except Exception:
                continue
    return ""


def build_request(host: str, port: int, sni: str, probes: int) -> dict:
    request_options = {"method": "HEAD"}
    # Без этого зонд отправит в SNI сам адрес, и прокси, отвечающий только на
    # своём имени, выглядел бы сломанным при полностью рабочей маскировке.
    if sni:
        request_options["host"] = sni
    return {
        "type": "http",
        "target": host,
        "measurementOptions": {
            "protocol": "HTTPS",
            "port": port,
            "request": request_options,
        },
        "locations": [{"country": "RU", "tags": [EYEBALL_TAG]}],
        "limit": probes,
    }


def analyze(measurement: dict) -> dict:
    """Сводит ответ Globalping к вердикту. Чистая функция, сети не касается."""
    results = measurement.get("results") or []
    total = len(results)
    success = 0
    reasons: dict[str, int] = {}
    for item in results:
        result = item.get("result") or {}
        # Именно рукопожатие: статус finished И наличие блока tls.
        if result.get("status") == "finished" and result.get("tls"):
            success += 1
            continue
        reason = (result.get("rawOutput") or "").strip()
        if not reason:
            reason = "зонд не ответил вовремя" if result.get("status") == "in-progress" \
                else "соединение не установлено"
        reasons[reason] = reasons.get(reason, 0) + 1
    pct = (success / total * 100.0) if total else 0.0
    return {"success": success, "total": total, "pct": pct, "reasons": reasons}


async def check(host: str, port: int, sni: str, probes: int,
                token: str = "", wait_seconds: int = 40) -> dict:
    """
    Прогоняет проверку и возвращает вердикт analyze().

    Бросает RateLimited при исчерпании часового бюджета и GlobalpingError на
    прочих отказах — вызывающий обязан их различать: в первом случае повторять
    нельзя, во втором можно.
    """
    if not host or not port:
        raise GlobalpingError("не задан адрес или порт прокси")

    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    async with httpx.AsyncClient(timeout=20.0) as client:
        resp = await client.post(f"{API_URL}/measurements",
                                 json=build_request(host, port, sni, probes),
                                 headers=headers)
        if resp.status_code == 429:
            raise RateLimited(
                "исчерпан часовой бюджет Globalping. Кредиты считаются по зондам: "
                "уменьшите их число или увеличьте интервал"
            )
        if resp.status_code not in (200, 201, 202):
            raise GlobalpingError(f"сервис проверки ответил {resp.status_code}")
        measurement_id = (resp.json() or {}).get("id")
        if not measurement_id:
            raise GlobalpingError("сервис не вернул идентификатор проверки")

        # Ждём завершения. Не один запрос со сном: зонды отвечают вразнобой, и
        # фиксированная пауза либо тормозит, либо забирает недособранный ответ.
        deadline = asyncio.get_event_loop().time() + wait_seconds
        while True:
            got = await client.get(f"{API_URL}/measurements/{measurement_id}",
                                   headers={"Accept": "application/json"})
            if got.status_code != 200:
                raise GlobalpingError(f"сервис проверки ответил {got.status_code}")
            data = got.json() or {}
            if data.get("status") == "finished":
                return analyze(data)
            if asyncio.get_event_loop().time() >= deadline:
                # Отдаём то, что успело прийти: частичный результат полезнее
                # молчания, а незавершённые зонды считаются неудачей.
                logging.warning("[globalping] проверка не завершилась за %s с, "
                                "считаю по собранному", wait_seconds)
                return analyze(data)
            await asyncio.sleep(2)


def budget_fits(interval_minutes: int, probes: int, has_token: bool) -> Optional[str]:
    """
    Проверяет, укладывается ли расписание в бесплатный бюджет.

    Возвращает текст предупреждения или None. Считать до включения дешевле, чем
    ловить 429 в бою: сервис не откажет частично, он откажет целиком.
    """
    budget = 500 if has_token else 250
    if interval_minutes <= 0 or probes <= 0:
        return None
    per_hour = (60 // max(interval_minutes, 1)) * probes
    if per_hour > budget:
        return (f"расписание тратит {per_hour} кредитов в час при бюджете {budget}: "
                f"часть проверок будет пропущена")
    return None
