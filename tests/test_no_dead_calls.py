"""
После отказа от MTProxyL-Panel никто не зовёт удалённые функции.

ЗАЧЕМ. 23.09.2026 из VSM убрали всё, что ставило и настраивало MTProxyL-Panel.
Искал я вызовы по приставке mtpl_ — и пропустил _panel_do_install_mtproxyl в
пункте «MTProxyL»: после установки инструмента меню предлагало поставить
панель функцией, которой больше нет. Хуже того, перед установкой там же стоял
страж, предлагавший удалить работающую telemt_panel, — ради инструмента,
которому она ничем не мешает. Увидел это владелец, а не проверки: приёмка меню
заходит в этот пункт на стенде, где MTProxyL уже стоит, то есть в другую ветку.

ShellCheck вызов несуществующей функции не ловит: для него это просто команда,
которая найдётся или не найдётся во время работы. Поэтому здесь явный список
удалённого и поиск по всем файлам, кроме комментариев.

Граница проверки названа вслух: она знает только эти имена. Новое удаление —
новые имена в список.
"""
import re
from pathlib import Path

КОРЕНЬ = Path(__file__).resolve().parent.parent

УДАЛЁННЫЕ = (
    "_panel_do_install_mtproxyl",
    "_sudo_flavor",
    "_panel_warn_sudo_rs",
    "mtpl_restore_proxy",
    "mtpl_proxy_render",
    "mtpl_proxy_apply",
    "mtpl_panel_prefix",
    "mtpl_panel_url",
    "mtpl_panel_user",
    "mtpl_panel_port",
    "mtpl_panel_set_prefix",
    "mtpl_panel_is_local",
    "_mtpl_panel_configurable",
    "nginx_mtpl_proxy.sh",
)


def файлы():
    for путь in list(КОРЕНЬ.glob("lib/*.sh")) + list(КОРЕНЬ.glob("menus/*.sh")) \
            + list(КОРЕНЬ.glob("stacks/*.sh")) + list(КОРЕНЬ.glob("checks/*.sh")) \
            + list(КОРЕНЬ.glob("tools/*.sh")) + [КОРЕНЬ / "vsm", КОРЕНЬ / "install.sh"]:
        if путь.is_file():
            yield путь


def код_без_комментариев(текст):
    """Строки, у которых первый непробельный символ не #."""
    for номер, строка in enumerate(текст.splitlines(), 1):
        if строка.lstrip().startswith("#"):
            continue
        yield номер, строка


def test_удалённые_функции_никто_не_зовёт():
    найдено = []
    for путь in файлы():
        текст = путь.read_text(encoding="utf-8", errors="replace")
        for номер, строка in код_без_комментариев(текст):
            for имя in УДАЛЁННЫЕ:
                if re.search(r"(?<![\w.-])" + re.escape(имя) + r"(?![\w])", строка):
                    найдено.append(f"{путь.relative_to(КОРЕНЬ)}:{номер}: {имя}")
    assert not найдено, (
        "зовут то, чего больше нет — упадёт только во время работы:\n  "
        + "\n  ".join(найдено)
    )


def test_проверка_видит_вызов():
    """Обратная сторона: поиск, который ничего не находит никогда, бесполезен."""
    образец = "        *)     _panel_do_install_mtproxyl ;;\n"
    строки = [с for _, с in код_без_комментариев(образец)]
    assert any("_panel_do_install_mtproxyl" in с for с in строки)


def test_комментарий_вызовом_не_считается():
    образец = "        # прежде тут звали mtpl_restore_proxy\n"
    assert list(код_без_комментариев(образец)) == []


def test_установка_mtproxyl_не_трогает_панели():
    """
    Сам повод. Пункт «MTProxyL» не должен звать стража панелей: инструмент
    в режиме реаниматора панель не ставит и ничем ей не мешает.
    """
    текст = (КОРЕНЬ / "menus" / "telemt.sh").read_text(encoding="utf-8")
    вызовы = [
        номер for номер, с in код_без_комментариев(текст)
        if "panel_ensure_exclusive" in с and "mtproxyl" in с
    ]
    assert not вызовы, f"страж панелей снова в установке MTProxyL, строки {вызовы}"
