"""
Снятие блока панели не кладёт копию рядом с vhost.

ЗАЧЕМ. vhost лежит в sites-enabled, а nginx включает sites-enabled/* целиком.
panel_proxy_remove сохранял копию как `${vhost}.vsm-bak` — рядом, — и nginx
подхватывал её вторым конфигом:
    [emerg] limit_req_zone "diag_api" is already bound
Проверка конфигурации падала, снятие откатывалось. Замерено на стенде
23.09.2026 при снятии MTProxyL-Panel.

В panel_proxy_apply_block это починили ещё 04.09.2026; сюда исправление не
дошло. Три недели это прятала ДРУГАЯ ошибка: поиск vhost отдавал
sites-available, куда nginx не смотрит, и копия там никому не мешала. Починили
поиск — вылезла копия.

Поддельный nginx ведёт себя как настоящий в том, что здесь важно: считает
конфигом КАЖДЫЙ файл каталога и падает, если их больше одного.
"""
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
БИБЛИОТЕКА = КОРЕНЬ / "lib" / "nginx_panel_proxy.sh"

pytestmark = pytest.mark.skipif(
    not БИБЛИОТЕКА.is_file() or shutil.which("bash") is None or os.name == "nt",
    reason="нужны lib/nginx_panel_proxy.sh, bash и POSIX",
)

НАЧАЛО = "# >>> VSM MTProxyL-Panel proxy"
КОНЕЦ = "# <<< VSM MTProxyL-Panel proxy"

VHOST = f"""\
server {{
    listen 7443 ssl;
    ssl_certificate /x.pem;
    limit_req_zone $binary_remote_addr zone=diag_api:1m rate=1r/s;
{НАЧАЛО}
    location /старый/ {{ proxy_pass http://127.0.0.1:8080/старый/; }}
{КОНЕЦ}
    location / {{ root /var/www/html; }}
}}
"""


def окружение(tmp_path):
    включённые = tmp_path / "sites-enabled"
    копии = tmp_path / "backups"
    bin_ = tmp_path / "bin"
    for к in (включённые, копии, bin_):
        к.mkdir()
    vhost = включённые / "adk.example.com"
    vhost.write_text(VHOST, encoding="utf-8")

    # nginx -t: как настоящий, читает ВСЕ файлы каталога.
    nginx = bin_ / "nginx"
    nginx.write_text(
        "#!/bin/sh\n"
        f'n=$(ls -1 "{включённые.as_posix()}" | wc -l)\n'
        'if [ "$n" -gt 1 ]; then\n'
        '  echo "[emerg] limit_req_zone \\"diag_api\\" is already bound" >&2; exit 1\n'
        "fi\nexit 0\n"
    )
    systemctl = bin_ / "systemctl"
    systemctl.write_text("#!/bin/sh\nexit 0\n")
    for f in (nginx, systemctl):
        f.chmod(f.stat().st_mode | stat.S_IEXEC)
    return vhost, включённые, копии, bin_


def снять(vhost, копии, bin_):
    скрипт = (
        f'. "{БИБЛИОТЕКА.as_posix()}"\n'
        f'panel_proxy_remove "$1" "{НАЧАЛО}" "{КОНЕЦ}"'
    )
    return subprocess.run(
        ["bash", "-c", скрипт, "vsm-test", vhost.as_posix()],
        capture_output=True, text=True, encoding="utf-8",
        env={**os.environ,
             "PATH": f"{bin_.as_posix()}:{os.environ.get('PATH', '')}",
             "PANEL_PROXY_BACKUP_DIR": копии.as_posix()},
    )


def test_снятие_проходит(tmp_path):
    vhost, _, копии, bin_ = окружение(tmp_path)
    ответ = снять(vhost, копии, bin_)
    assert ответ.returncode == 0, (
        "снятие откатилось — копия рядом с vhost стала вторым конфигом:\n"
        + ответ.stderr
    )


def test_блок_действительно_снят(tmp_path):
    vhost, _, копии, bin_ = окружение(tmp_path)
    снять(vhost, копии, bin_)
    текст = vhost.read_text(encoding="utf-8")
    assert НАЧАЛО not in текст and "/старый/" not in текст, текст


def test_соседние_директивы_на_месте(tmp_path):
    """Обратная сторона: снимаем блок, а не всё вокруг."""
    vhost, _, копии, bin_ = окружение(tmp_path)
    снять(vhost, копии, bin_)
    текст = vhost.read_text(encoding="utf-8")
    assert "limit_req_zone" in текст
    assert "location / { root /var/www/html; }" in текст


def test_рядом_с_vhost_ничего_не_осталось(tmp_path):
    vhost, включённые, копии, bin_ = окружение(tmp_path)
    снять(vhost, копии, bin_)
    assert sorted(p.name for p in включённые.iterdir()) == [vhost.name]


def test_копия_лежит_в_каталоге_копий(tmp_path):
    vhost, _, копии, bin_ = окружение(tmp_path)
    снять(vhost, копии, bin_)
    assert any(копии.iterdir()), "копии нет — откатиться было бы не из чего"


def test_при_отказе_nginx_файл_возвращается(tmp_path):
    """Если nginx конфиг не принял — vhost обязан вернуться к прежнему виду."""
    vhost, включённые, копии, bin_ = окружение(tmp_path)
    (bin_ / "nginx").write_text("#!/bin/sh\necho '[emerg] сломано' >&2; exit 1\n")
    ответ = снять(vhost, копии, bin_)
    assert ответ.returncode != 0
    assert vhost.read_text(encoding="utf-8") == VHOST
