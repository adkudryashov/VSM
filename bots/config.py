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
