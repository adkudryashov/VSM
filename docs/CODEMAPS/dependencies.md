<!-- Generated: 2026-08-05 | Файлов просканировано: 20 | Оценка: ~700 токенов -->

# Внешние зависимости

## Сторонние проекты, устанавливаемые меню

| Проект | Откуда | Как тянется | Пиннинг | Отпечаток |
|---|---|---|---|---|
| [3x-ui-pro](https://github.com/mozaroc/3x-ui-pro) | `raw.githubusercontent.com/mozaroc/3x-ui-pro/main` | `x-ui-latest.sh` через `xui_installer_fetch`: сверка + снятие `check_cpu` | **нет**, ветка `main` | **да** |
| 3x-ui-pro patch | тот же репозиторий | `x-ui-patch.sh`, `check_cpu` там нет | **нет** | **да** |
| [telemt](https://github.com/telemt/telemt) | install.sh апстрима | `curl \| sh` с аргументами | **нет** | нет |
| [telemt_panel](https://github.com/amirotin/telemt_panel) | install.sh апстрима | ответы подаются через `script` вслепую позиционно | **нет** | нет |
| [MTProxyL](https://github.com/Liafanx/MTProxyL) | `main` | лимитер, режим Reanimator | **нет** | нет |
| AdGuard Home | `x-ui-adguard.sh` из 3x-ui-pro | | **нет** | нет |
| x-ui-backup | `assets/backup/x-ui-backup.sh` из 3x-ui-pro | `wget` в `/usr/local/bin` | **нет** | нет |
| [awg-containers-and-tools](https://github.com/Vadim-Khristenko/awg-containers-and-tools) | GitHub Releases + Docker Hub | `awg-tool` по тегу, образы 2.0 и 3.0 по digest | **да**, тег + digest | сверка официальной sha256 |

Отсутствие пиннинга — известный риск: всё это выполняется от root. Решение
владельца — запоминать отпечаток и предупреждать при изменении, а не
фиксировать версии.

`upstream_fingerprint` в `lib/common.sh` считает sha256 и сверяет с
`/etc/vsm/upstream.sha256`. Незнакомый адрес запоминается молча, совпадение
проходит без слова, расхождение печатает оба отпечатка и не блокирует —
блокировать решено не было. Своя минимальная копия живёт в `stacks/telemt.sh`:
установщик самодостаточен, как и с `wait_for_apt`.

Покрыты пути 3x-ui-pro и ipregion. AmneziaWG пиннится иначе и жёстче: релиз
`awg-tool` сверяется с опубликованной автором sha256, образы фиксируются по
digest. Остальные апстримы — следующим заходом.

**Три поверхности обновления у AmneziaWG.** Репозиторий, релиз бинарника и
образы на Docker Hub меняются независимо, причём образы публикуются отдельно
от GitHub — тег там способен переехать без единого коммита. Пункт меню
«Проверить обновления» спрашивает digest у реестра заголовком
`Docker-Content-Digest`: `docker manifest inspect` отдаёт digest'ы манифестов
под отдельные архитектуры, и сравнение с зафиксированным digest'ом списка
манифестов давало бы «изменился» всегда.

**Почему это понадобилось.** 6 августа автор 3x-ui-pro удалил разбор
`-auto_domain` (коммит `18a2e01`). VSM продолжал его передавать, а ветка
`*) shift 1` в разборе аргументов проглатывает неизвестный флаг молча — ни
ошибки, ни предупреждения. Путь «автоопределение доменов» после этого отдавал
установщику пустые домены, и тот уходил в бесконечный `read`.

## Данные

| Источник | Что | Где используется |
|---|---|---|
| [P3TERX/GeoLite.mmdb](https://github.com/P3TERX/GeoLite.mmdb) | GeoLite2 City / ASN / Country, `releases/latest` | `update_geoip.sh`, переопределяется `GEOIP_BASE_URL` |
| [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) | база для RealiTLScanner | `menus/tests.sh` |
| [openssl/openssl](https://github.com/openssl/openssl) | исходники 3.5.x | `stacks/nginx-openssl35.sh` |

Прежний источник GeoIP (`git.io`) отключён GitHub в 2022 — базы не скачивались
вовсе, а скрипт рапортовал об успехе.

## Инструменты диагностики (запускаются, не устанавливаются)

`censorcheck.tlab.pw` · [ipregion](https://github.com/vernette/ipregion) ·
[RealiTLScanner](https://github.com/XTLS/RealiTLScanner) ·
[dpi-detector](https://github.com/Runnin4ik/dpi-detector) ·
[sni-scan](https://github.com/dewil/sni-scan) ·
[YABS](https://github.com/masonr/yet-another-bench-script) · `bench.sh` ·
[IPQuality](https://github.com/xykt/IPQuality) ·
[russian-iperf3-servers](https://github.com/itdoginfo/russian-iperf3-servers)

## Системные пакеты

Ставятся через `ensure_packages` / `wait_for_apt`:
`git curl jq bc qrencode ufw acl python3 python3-venv wget`

`wait_for_apt` обязателен: на свежем VPS первые минуты работает
`unattended-upgrades` и держит блокировку dpkg, из-за чего пакеты молча не
ставятся.

## Python-зависимости ботов

`bots/requirements.txt` → venv в `bots/venv`. Ключевые: `aiogram`, `aiohttp`,
`geoip2`, `folium`, `pydantic`. 32 файла в `bots/`, точки входа —
`run_combined.py`, `run_telemt.py`, `run_xui.py`.

## Хрупкие места

- **Ответы установщику telemt_panel подаются позиционно** (`\n\n user \n pass \n\n\n`). Апстрим добавит вопрос — пароль уедет в соседнее поле, а файл учётных данных будет уверенно показывать неверное.
- **Патч 3x-ui-pro вычищает `sites-enabled`** — блок доступа к telemt_panel исчезает, маска в `conf.d` выживает.
- **Удаление панели вычищает `/etc/nginx` целиком** — вместе с маской и webroot; telemt падает следом по `Requires=`.
- **Контейнер AmneziaWG непригоден в роли клиента**: его entrypoint кладёт `fwmark` в секцию пира, тогда как в UAPI это ключ интерфейса, и демон отвергает конфиг с `errno=-22`. Проявляется только при `AllowedIPs = 0.0.0.0/0`. На роль сервера, в которой его использует VSM, не влияет — проверено на стенде.

Выдаваемые конфиги проверяются эталонной реализацией: `apt install amneziawg amneziawg-tools` из `ppa:amnezia/ppa`, затем `awg-quick up` в отдельном netns. Имя интерфейса обязано отличаться от `awg0` — его держит сервер в host-режиме.
