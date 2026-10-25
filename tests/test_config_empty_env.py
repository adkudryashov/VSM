"""
Пустые значения в bots/.env — это «не задано», а не ошибка разбора.

ЗАЧЕМ. На сервере без стека telemt установщик пишет `RU_CHECK_PORT=` (порт
берётся из /etc/vsm/telemt.conf, а его нет), и бот 3x-ui падал при запуске:
pydantic не разбирает пустую строку как число. Ни одна установка бота без
telemt не поднималась — сообщение пользователя 25.10.2026.

Файл .env пишется ровно так, как его пишет stacks/bots.sh, и читается настоящим
классом Settings.
"""
from config import Settings

ENV_БЕЗ_TELEMT = """\
XUI_BOT_TOKEN=123:abc
ADMIN_IDS=[1]
TELEMT_API_KEY=
WEB_URL=
WATCHDOG_ENABLED=false
RU_CHECK_ENABLED=false
RU_CHECK_INTERVAL_MINUTES=60
RU_CHECK_PROBES=10
RU_CHECK_TOKEN=
RU_CHECK_PORT=
RU_CHECK_SNI=
RU_CHECK_SOURCE=auto
"""


def test_пустой_порт_даёт_умолчание(tmp_path):
    env = tmp_path / ".env"
    env.write_text(ENV_БЕЗ_TELEMT, encoding="utf-8")
    s = Settings(_env_file=env)
    assert s.RU_CHECK_PORT == 0
    assert s.RU_CHECK_SNI == ""
    assert s.XUI_BOT_TOKEN == "123:abc"
    assert s.ADMIN_IDS == [1]


def test_заданный_порт_читается(tmp_path):
    env = tmp_path / ".env"
    env.write_text(ENV_БЕЗ_TELEMT.replace("RU_CHECK_PORT=\n", "RU_CHECK_PORT=8444\n"),
                   encoding="utf-8")
    assert Settings(_env_file=env).RU_CHECK_PORT == 8444
