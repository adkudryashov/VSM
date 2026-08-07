<!-- Generated: 2026-08-05 | Файлов просканировано: 12 | Оценка: ~600 токенов -->

# Данные и состояние на сервере

Базы данных как таковой нет: состояние — файлы конфигурации плюс sqlite ботов.

## Файлы VSM

| Путь | Содержимое | Права | Кто пишет |
|---|---|---|---|
| `/root/VSM` | клон репозитория, команды — симлинки из `/usr/local/bin` | — | `install.sh` |
| `/etc/vsm/telemt.conf` | домены, порты, `TELEMT_SECRET`, префикс и учётки telemt_panel | 600 | `telemt-stack.sh` |
| `/etc/vsm/telemt-credentials.txt` | то же в читаемом виде | 600 | `telemt-stack.sh` |
| `/etc/vsm/xui.conf` | логин и пароль панели 3x-ui, введённые вручную | 600 | `xui_credentials_save` |
| `/etc/vsm/bots.conf` | токены, `ADMIN_IDS`, `MAP_DOMAIN`, `MAP_PATH`, `BOTS_MODE` | 600 | `bots-stack.sh` |
| `/etc/vsm/upstream.sha256` | `<url> <sha256> <дата>` для сторонних установщиков | 600 | `upstream_fingerprint` |
| `/etc/vsm/awg.conf` | порт, профиль мимикрии и пиннинг AmneziaWG | 600 | `awg-stack.sh` |
| `/etc/vsm/awg/server.conf` | ключ сервера и параметры обфускации 3.0 | 600 | `awg-stack.sh` |
| `/root/VSM/bots/.env` | окружение ботов | 600 | `bots-stack.sh` |

Пароль панели 3x-ui **прочитать с сервера нельзя**: установщик генерирует его
случайно, печатает один раз и не сохраняет, панель хранит bcrypt-хэш.
`/etc/vsm/xui.conf` — записная книжка, заполняется вручную.

## Файлы сторонних компонентов

| Путь | Что |
|---|---|
| `/etc/nginx/conf.d/telemt-mask.conf` | vhost self-SNI маскировки, переживает патч панели |
| `/etc/nginx/sites-available/<домен>` | vhost панели; здесь же блок доступа к telemt_panel |
| `/etc/telemt/telemt.toml` | конфиг telemt, секция `[censorship]` |
| `/etc/telemt-panel/config.toml` | `listen = "127.0.0.1:9444"`, секции `[tls]` нет |
| `/etc/x-ui/x-ui.db` | sqlite панели: инбаунды, пользователи, bcrypt-пароль |
| `/etc/letsencrypt/live/<домен>/` | сертификаты; переживают удаление панели |
| `/var/backups/vsm/nginx/` | бэкапы vhost вне include-путей nginx |

## Данные ботов

```
bots/data/
  ip_history.db      история подключений по IP
  activity.db        активность
  bot_monitor.db     список панелей 3x-ui
  geoip/
    GeoLite2-City.mmdb   ~63 МБ
    GeoLite2-ASN.mmdb
    GeoLite2-Country.mmdb
```

Каталог переживает смену режима бота и удаление ботов. Путь читается
`bots/config.py:44-45`; скрипт обновления баз обязан класть файлы **туда же**.

## Карта подключений

`/var/www/telemt-map/map.html` — список всех различных IP пользователей прокси
с городом и провайдером. Отдаётся по случайному пути из `MAP_PATH`, каталог
750, группа `www-data`. На домен маскировки вешать нельзя: маска не зеркалит
`location`, и один и тот же адрес отвечал бы по-разному на 443 и на порту
telemt. Удаление ботов снимает и файл, и блок из nginx.

## Порты

| Порт | Что | Доступ |
|---|---|---|
| 443 | панель 3x-ui, сайт, telemt_panel | извне |
| 8444 | telemt (MTProto) | извне |
| 7443 | vhost панели за stream, `proxy_protocol` | только `127.0.0.1` |
| 7444 | цель self-SNI маскировки | только `127.0.0.1` |
| 9444 | telemt_panel | только `127.0.0.1` |
| 9091 | API telemt | только `127.0.0.1` |
