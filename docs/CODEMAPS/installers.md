<!-- Generated: 2026-08-05 | Файлов просканировано: 5 | Оценка: ~800 токенов -->

# Установщики

Запускаются меню, но пригодны и отдельно. **Не подключают `_config_and_utils.sh`** —
общие помощники продублированы осознанно, это дешевле связности. У обоих
`set -euo pipefail`, поэтому каждая подстановка команды требует `|| true`.

## `telemt-stack.sh` (477 строк)

Режимы: `--mode full` (ставит и панель) | `--mode addon` (панель уже есть).

```
Этап 0  проверки: root, ОС, два разных домена, резолв, свободные порты
Этап 1  3x-ui-pro (только full) — качает x-ui-latest.sh, снимает check_cpu
Этап 2  self-SNI vhost → nginx_mask_apply (общий с меню)
        + wait_until 30 mask_responds, иначе die
Этап 3  telemt: install.sh апстрима, дроп-ин Requires=nginx.service,
        toml_set_in_section в [censorship], сквозной тест через :8444
Этап 4  telemt_panel: ответы установщику подаются через script с stty -echo,
        затем panel_proxy_localize → 127.0.0.1, [tls] снят, ACL отозван,
        правило ufw для порта снято
Этап 5  panel_proxy_apply → блок в vhost панели, затем panel_proxy_verify
        (опрос до 30 с: systemd возвращает управление раньше готовности)
```

Сохранение состояния:

```
/etc/vsm/telemt.conf              printf %q, 600
  DOMAIN_PANEL DOMAIN_REALITY TELEMT_PORT TELEMT_MASK_PORT
  PANEL_PORT PANEL_PREFIX TELEMT_SECRET PANEL_ADMIN_USER PANEL_ADMIN_PASS
/etc/vsm/telemt-credentials.txt   читаемый вид, 600
```

Секрет и пароль **переиспользуются**: читаются из существующего конфига до
генерации новых.

## `bots-stack.sh` (377 строк)

```
0  migrate_old_layout   переносит .db и geoip из прежней раскладки в bots/data
1  системные пакеты     проверка ensurepip (не venv!), wait_for_apt inline
2  venv                 проверка bin/python И bin/pip, --clear чинит полуфабрикат
3  .env + bots.conf     umask 077 перед записью
4  fetch_geoip          update_geoip.sh <dir>, успех по факту наличия файлов
5  setup_nginx_map      nginx_map_location.py --path <случайный> --mask-domain
6  systemd              write_unit, stop_unit для лишних режимов, start_and_check
```

## Генераторы nginx

`_nginx_mask.sh` (292):
```
nginx_mask_panel_vhost   ищет vhost домена в sites-available | sites-enabled
nginx_mask_tls_block     вырезает server{} с ssl_certificate (не блок :80!)
nginx_mask_scrape        root, cert, key — из TLS-блока, комментарии отсеяны
nginx_mask_scrape_tls    зеркалит TLS-директивы панели по белому списку
nginx_mask_render        текст vhost; ssl_* НЕ захардкожены
nginx_mask_install       атомарная подмена через mv + nginx -t + откат
nginx_mask_apply         полный цикл, единственная точка входа
```

`_nginx_panel_proxy.sh` (311):
```
panel_proxy_gen_prefix   openssl rand -hex 16
panel_proxy_render       location + proxy_pass + sub_filter для <base href>
panel_proxy_strip        снятие блока по маркерам
panel_proxy_insert       вставка перед } блока с ssl_certificate
panel_proxy_apply        strip → insert → nginx -t → reload, с откатом
panel_proxy_localize     панель на loopback, [tls] снят, ACL и ufw убраны
panel_proxy_verify       опрос до 30 с, успех только по коду ответа
panel_proxy_remove       снятие при удалении стека
```

Блок панели живёт в `sites-enabled` и **не переживает патч 3x-ui-pro** —
переприменяется пунктом 4. Маска в `conf.d` переживает.

## `rebuild-nginx-openssl35.sh` (183)

Читает `configure`-флаги текущего nginx, пересобирает с OpenSSL 3.5 в
`/opt/openssl-3.5`, подменяет `/usr/sbin/nginx` с бэкапом и откатом, делает
`apt-mark hold`. Динамические модули (включая `stream`) становятся статическими.
20–40 минут на одном ядре.
