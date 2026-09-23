"""
Таймер сторожа бота включается только после запуска самого бота.

ЗАЧЕМ. vsm-heartbeat.timer стоит на OnBootSec=2min — отсчёт от загрузки
сервера. На машине, которая работает давно, эти две минуты давно прошли, и
`systemctl enable --now` запускает проверку немедленно. Установщик включал
таймер ДО бота, и первая установка начиналась с «🆘 БОТ НЕ РАБОТАЕТ»:
проверка в 19:11:48, бот поднят в 19:11:49. Замерено 23.09.2026 на новом
сервере. Повторная установка этого не показывает — там бот уже работает.
"""
from pathlib import Path

УСТАНОВЩИК = Path(__file__).resolve().parent.parent / "stacks" / "bots.sh"


def _строка(текст, образец):
    for номер, строка in enumerate(текст.splitlines(), 1):
        if образец in строка and not строка.lstrip().startswith("#"):
            return номер
    raise AssertionError(f"не найдено в stacks/bots.sh: {образец}")


def test_таймер_сторожа_после_запуска_ботов():
    текст = УСТАНОВЩИК.read_text(encoding="utf-8")
    таймер = _строка(текст, "enable -q --now vsm-heartbeat.timer")
    for бот in ("start_and_check 3xui-telemt-bot",
                "start_and_check telemt-bot",
                "start_and_check 3xui-monitor"):
        assert _строка(текст, бот) < таймер, (
            f"таймер сторожа включается раньше, чем {бот} — "
            "первая установка начнётся с ложной тревоги"
        )
