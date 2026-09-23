"""
Поиск vhost домена: правим тот файл, который читает nginx.

ЗАЧЕМ. После обновления 3x-ui через её меню на стенде sites-available и
sites-enabled оказались ДВУМЯ ОБЫЧНЫМИ ФАЙЛАМИ с разными inode. nginx читает
sites-enabled, а nginx_mask_panel_vhost первым отдавал sites-available. Итог,
замеренный 23.09.2026 при переводе стенда на telemt_panel: блок новой панели лёг
в файл, который nginx не читает, и секретный путь отдавал 404; снятие старой
панели вычистило её блок оттуда же, и живой nginx продолжал проксировать её
путь на мёртвый порт.

Это уже чинили — дважды, в двух копиях той же функции (для WEB Proxy и для
позиции реестра). Оригинал остался прежним. Поэтому здесь две части: поведение
самой функции на всех трёх раскладках — и то, что копий больше нет.
"""
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
БИБЛИОТЕКА = КОРЕНЬ / "lib" / "nginx_mask.sh"
ДОМЕН = "adk.example.com"

pytestmark = pytest.mark.skipif(
    not БИБЛИОТЕКА.is_file() or shutil.which("bash") is None,
    reason="нужны lib/nginx_mask.sh и bash",
)


def найти(корень):
    ответ = subprocess.run(
        ["bash", "-c", f'. "{БИБЛИОТЕКА.as_posix()}"\nnginx_mask_panel_vhost "$1"',
         "vsm-test", ДОМЕН],
        capture_output=True, text=True, encoding="utf-8",
        env={**os.environ, "VSM_NGINX_DIR": корень.as_posix()},
    )
    return ответ.stdout.strip(), ответ.returncode


def раскладка(tmp_path):
    for каталог in ("sites-available", "sites-enabled", "conf.d"):
        (tmp_path / каталог).mkdir()
    return tmp_path


def test_два_отдельных_файла_берём_включённый(tmp_path):
    """Тот самый случай стенда: разные inode, nginx читает sites-enabled."""
    корень = раскладка(tmp_path)
    (корень / "sites-available" / ДОМЕН).write_text("старая копия\n")
    (корень / "sites-enabled" / ДОМЕН).write_text("то, что читает nginx\n")
    путь, код = найти(корень)
    assert код == 0
    assert Path(путь) == (корень / "sites-enabled" / ДОМЕН).resolve(), (
        f"выбран {путь} — правка уйдёт в файл, который nginx не читает"
    )


def test_ссылка_разворачивается(tmp_path):
    """
    Свежая установка: sites-enabled — ссылка. Отдать надо файл, а не ссылку:
    sed -i по ссылке заменил бы её обычным файлом, и две копии тихо разошлись.
    """
    корень = раскладка(tmp_path)
    настоящий = корень / "sites-available" / ДОМЕН
    настоящий.write_text("vhost\n")
    try:
        (корень / "sites-enabled" / ДОМЕН).symlink_to(настоящий)
    except (OSError, NotImplementedError):
        pytest.skip("ссылки здесь создать нельзя")
    путь, код = найти(корень)
    assert код == 0
    assert Path(путь) == настоящий.resolve()
    assert not Path(путь).is_symlink()


def test_без_включённого_берём_доступный(tmp_path):
    """Обратная сторона: включённого файла нет — не отказываем, берём что есть."""
    корень = раскладка(tmp_path)
    (корень / "sites-available" / ДОМЕН).write_text("vhost\n")
    путь, код = найти(корень)
    assert код == 0
    assert Path(путь) == (корень / "sites-available" / ДОМЕН).resolve()


def test_conf_d_раньше_недоступного(tmp_path):
    корень = раскладка(tmp_path)
    (корень / "conf.d" / f"{ДОМЕН}.conf").write_text("vhost\n")
    (корень / "sites-available" / ДОМЕН).write_text("не читается\n")
    путь, _ = найти(корень)
    assert Path(путь) == (корень / "conf.d" / f"{ДОМЕН}.conf").resolve()


def test_нет_ничего_отказ(tmp_path):
    путь, код = найти(раскладка(tmp_path))
    assert код != 0
    assert путь == ""


def test_реализация_одна():
    """
    Две прежние копии уже были исправлены, а оригинал — нет. Любая новая копия
    поиска по трём каталогам nginx — повод для этой проверки упасть.
    """
    образец = re.compile(r'for\s+candidate\s+in\s+"[^"]*sites-(enabled|available)/')
    копии = []
    for путь in list(КОРЕНЬ.glob("lib/*.sh")) + list(КОРЕНЬ.glob("menus/*.sh")) \
            + list(КОРЕНЬ.glob("stacks/*.sh")) + list(КОРЕНЬ.glob("checks/*.sh")):
        for номер, строка in enumerate(путь.read_text(encoding="utf-8").splitlines(), 1):
            if образец.search(строка):
                копии.append(f"{путь.relative_to(КОРЕНЬ)}:{номер}")
    assert len(копии) == 1 and копии[0].startswith("lib/nginx_mask.sh:"), (
        "поиск vhost должен жить ровно в одном месте, lib/nginx_mask.sh; найдено:\n  "
        + "\n  ".join(копии or ["нигде"])
    )
