from pathlib import Path
from typing import List

from pydantic_settings import BaseSettings

# Один конфиг на все точки входа. Раньше у каждого бота был свой config.py,
# и при объединении они конфликтовали: `import config` разрешался в тот, что
# оказался первым в sys.path.
BASE_DIR = Path(__file__).resolve().parent

# Данные общие для всех точек входа, поэтому переключение между отдельными
# ботами и объединённым не теряет ни историю IP, ни список панелей.
DATA_DIR = BASE_DIR / "data"


class Settings(BaseSettings):
    # --- Токены: у каждой точки входа свой бот в Telegram ---
    TELEMT_BOT_TOKEN: str = ""
    XUI_BOT_TOKEN: str = ""
    COMBINED_BOT_TOKEN: str = ""

    # --- Доступ. Общий список на все три бота ---
    ADMIN_IDS: List[int] = []

    # --- Панель Telemt ---
    TELEMT_API_URL: str = "http://127.0.0.1:9091"
    TELEMT_API_KEY: str = ""
    PROMETHEUS_METRICS_URL: str = "http://127.0.0.1:9090/metrics"
    COLLECT_INTERVAL_MINUTES: int = 1
    # 0 — хранить историю IP бессрочно
    ACTIVITY_RETENTION_HOURS: int = 0
    SERVER_NAME: str = "Telemt Server"
    CHECK_VERSION: bool = True
    WEB_URL: str = ""

    # --- Сторож telemt ---
    # Выключен по умолчанию: он шлёт сообщения сам, без запроса, и включать
    # такое за владельца нельзя.
    WATCHDOG_ENABLED: bool = False
    WATCHDOG_INTERVAL_SECONDS: int = 60
    # Сколько подряд плохих опросов до тревоги. Один ничего не значит: движок
    # перезапускается за секунды, и по одному промаху бот кричал бы на каждый
    # рестарт. Тот же приём, что XUI_FAILURES_BEFORE_ALERT у панелей.
    WATCHDOG_FAILURES_BEFORE_ALERT: int = 3
    # Порог доли живых писателей, ниже которого это уже авария.
    #
    # Не 100: на живом сервере часть дата-центров штатно недоступна. Замерено
    # на стенде при полностью рабочем прокси: available_pct 45.8 (11 из 24
    # точек), а у DC -5 вообще 0 доступных. Тревога на «любой ДЦ недоступен»
    # была бы непрерывной, поэтому смотрим на покрытие писателями целиком.
    WATCHDOG_COVERAGE_FLOOR_PCT: float = 50.0
    # Порог доли ЖЁСТКИХ отказов исходящих подключений — тех, что движок даже
    # не стал повторять. Замер на стенде при исправном прокси: обычных отказов
    # 52% (движок пробует несколько точек и берёт первую ответившую), жёстких —
    # ровно 0. Поэтому порог смотрит только на вторые, и 20% здесь — запас от
    # единичных всплесков, а не рабочее значение. Подробности в
    # telemt/watchdog/upstreams.py.
    WATCHDOG_HARD_FAIL_PCT: float = 20.0

    # --- Доступность из РФ (Globalping) ---
    # ЦЕНА ЭТОЙ ПРОВЕРКИ. Каждый прогон просит публичный сервис Globalping
    # подключиться к вашему прокси с домашних адресов в России. То есть это
    # регулярный внешний трафик К СЕРВЕРУ по расписанию плюс передача его
    # адреса и порта в стороннее API. Для сервера, который маскируется, это
    # заметность — владелец выбрал её осознанно, но умолчания здесь щадящие:
    # выключено, а при включении раз в час по 10 зондов, а не раз в 15 минут
    # по 20, как у источника идеи.
    RU_CHECK_ENABLED: bool = False
    RU_CHECK_INTERVAL_MINUTES: int = 60
    RU_CHECK_PROBES: int = 10
    # Без токена Globalping даёт 250 кредитов в час на IP, один кредит на зонд.
    RU_CHECK_TOKEN: str = ""
    # Пусто — узнать свой внешний адрес самостоятельно.
    RU_CHECK_HOST: str = ""
    RU_CHECK_PORT: int = 0
    # Домен FakeTLS. Без него зонд отправит в SNI сам адрес, и прокси, который
    # отвечает только на своё имя, выглядел бы сломанным.
    RU_CHECK_SNI: str = ""
    RU_CHECK_FLOOR_PCT: float = 50.0

    # --- Мониторинг панелей 3x-ui ---
    # Как часто фоновый цикл опрашивает панели, в секундах
    XUI_CHECK_INTERVAL_SECONDS: int = 60
    # Сколько подряд неудачных опросов до сообщения о падении.
    # 10 × 60 секунд ≈ 10 минут — как было до вынесения в настройку.
    XUI_FAILURES_BEFORE_ALERT: int = 10

    # --- Пути. Считаются от каталога bots/, абсолютных путей в коде нет ---
    GEOIP_CITY_DB: str = str(DATA_DIR / "geoip" / "GeoLite2-City.mmdb")
    GEOIP_ASN_DB: str = str(DATA_DIR / "geoip" / "GeoLite2-ASN.mmdb")
    IP_HISTORY_DB: str = str(DATA_DIR / "ip_history.db")
    PANELS_DB: str = str(DATA_DIR / "bot_monitor.db")
    # Вне репозитория: у /root права 700, nginx под www-data туда не попадёт
    MAP_HTML_PATH: str = "/var/www/telemt-map/map.html"

    class Config:
        env_file = BASE_DIR / ".env"
        env_file_encoding = "utf-8"


settings = Settings()
