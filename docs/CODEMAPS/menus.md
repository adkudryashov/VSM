<!-- Generated: 2026-08-05 | Файлов просканировано: 9 | Оценка: ~900 токенов -->

# Карта меню

Аналог маршрутов: пункт → функция → что вызывает. Нумерация совпадает с экраном.

## Главное меню — `vsm` (426 строк)

```
0 → show_access_info     5 → menus/tests.sh
1 → menus/xui.sh          6 → menus/setup.sh
2 → menus/awg.sh          7 → menus/utils.sh
3 → menus/telemt.sh       8 → git pull + ln -sf + exec (обновление)
4 → menus/bots.sh         X → выход в оболочку
```

Шапка: две строки сводки (ОС, ресурсы, аптайм, TCP CC, страна, адреса,
нагрузка) и статусы четырёх подсистем. Подробные характеристики убраны —
меню открывается при каждом входе по SSH, а читают их раз в жизни; полный
вывод остался в «Тестирование» → «Параметры сервера».

Блока АДРЕСА больше нет: адреса панелей содержат случайный путь, который и
есть защита от сканирования, а скриншот главного меню публичный. Всё уехало
в пункт 0 — инвариант 6.

`show_access_info` показывает адреса обеих панелей, учётные данные, порт и
профиль AmneziaWG, домены с назначением. Пароли скрыты до нажатия P,
печатаются один раз, экран чистится на выходе.

## Управление X-UI — `menus/xui.sh` (335 строк)

```
1 install_xui_pro        xui_installer_fetch: отпечаток + снятие check_cpu;
                       оба домена обязательны, автоопределения больше нет
2 patch_xui_pro          отпечаток + run_remote_script x-ui-patch.sh
   (учётные данные переехали на 3, AdGuard на 7; разрушающий пункт 8
    намеренно не сдвигался — правило «только от привычной позиции»)
3 manage_adguard         x-ui-adguard.sh, install | uninstall
4 manage_backup          ensure_backup_script → x-ui-backup backup|list|restore
5 manage_service_status_restart x-ui
6 x-ui                   штатное меню апстрима
7 manage_xui_credentials → xui_credentials_save (/etc/vsm/xui.conf, 600)
8 uninstall_xui_pro      УДАЛИТЬ; снимает apt-mark hold от пересборки, иначе
                       purge nginx не проходит; вычищает /etc/nginx целиком
```

`warn_telemt_after_panel_change` вызывается после 1 и 2: патч чистит
`sites-enabled`, а там живёт блок доступа к telemt_panel.

## Стек telemt — `menus/telemt.sh` (898 строк)

```
УСТАНОВКА
1 run_install full     СТЕРЕТЬ → stacks/telemt.sh --mode full
2 run_install addon    → stacks/telemt.sh --mode addon

ЭКСПЛУАТАЦИЯ
3 run_diagnostics      службы, порты, HTTP-коды, сквозной self-SNI тест
4 restore_mask         nginx_mask_apply + panel_proxy_localize + panel_proxy_apply
                       + mtpl_restore_proxy (MTProxyL-Panel, если установлена)
                       + panel_proxy_verify; здесь же миграция старых установок
5 check_tls_parity     отпечаток / протокол / шифр / группа / ALPN + PQ
6 show_credentials     telemt-credentials.txt, адрес панели подставляется живой
7 manage_services      telemt, telemt-panel

ДОПОЛНИТЕЛЬНО
8  run_mtproxyl        сторонний лимитер, режим Reanimator
9  run_rebuild_nginx   stacks/nginx-openssl35.sh, 20–40 минут; читает rc и
                       печатает фактическое состояние nginx/telemt/telemt-panel
10 uninstall_stack     УДАЛИТЬ; снимает блок панели и ACL на ключ LE
```

## Telegram-боты — `menus/bots.sh` (343 строки)

```
1 combined   3xui-telemt-bot     ─┐
2 both       telemt-bot + 3xui-monitor │ взаимоисключающие,
3 telemt     telemt-bot          │ stop_unit снимает лишние
4 3xui       3xui-monitor        ─┘
5 run_update       git reset --hard + pip + restart
6 manage_watchdog  сторож: тревоги и доступность из РФ
7 show_settings
8 управление службами
9 run_remove       УДАЛИТЬ; снимает карту из nginx и /var/www/telemt-map
```

Все четыре режима вызывают `stacks/bots.sh --bots <режим>`.

### Сторож telemt (пункт 6)

Пять событий, все парами «тревога — восстановление»: движок недоступен,
движок перезапустился, просели писатели, изменился `config_hash` движка,
сменился внешний адрес. Тревога после трёх плохих опросов подряд, отбой сразу;
отбой без предшествующей тревоги не отправляется. Состояние в
`bots/data/watchdog.json` переживает перезапуск бота.

Проверка доступности из РФ (Globalping) выключена по умолчанию и включается
вводом слова после показа полной цены: каждый прогон приводит к серверу
российские зонды и отдаёт его адрес в стороннее API. Порт и SNI берутся из
`/etc/vsm/telemt.conf`, а не спрашиваются.

Настройки живут в `bots.conf` и переносятся в `.env` установщиком: оба файла
`stacks/bots.sh` создаёт заново, и без переноса переустановка режима молча
гасила бы сторож.

Команды в боте: `/watch`, `/check`, `/mute [30|2h]`, `/unmute`.

## Настройка — `menus/setup.sh` (554 строки)

```
1 show_bbr_menu     enable_bbr / disable_bbr, sysctl.conf
2 show_ping_menu    manage_ping_logic, правит /etc/ufw/before.rules
3 show_ufw_menu     ufw_enable_safely — разрешает SSH ДО включения
4 set_timezone_menu
5 manage_ssl_menu   certbot --standalone; trap INT TERM HUP → restore_stopped_services
6 menus/warp.sh
```

`ufw_enable_safely` объединяет источники SSH-порта: `$SSH_CONNECTION`,
`sshd -T`, `sshd_config.d`, `ss`. Порт панели наружу не открывает.

## Прочее

- `menus/tests.sh` (261) — IP region, доступность из РФ, iPerf3, YABS, IPQuality, sysbench, RealiTLScanner, DPI Detector, SNI Scan
- `menus/utils.sh` (190) — htop, ncdu, nethogs, внешний IP, ping/mtr, порты, kill, очистка, проверка домена
- `menus/warp.sh` (256) — Cloudflare WARP в режиме SOCKS5

IPv6 отдельным файлом больше не живёт: `show_ipv6_menu` внутри
`menus/setup.sh`, пункт 4. Прежний `ipv6-menu` был единственным меню без
префикса, со своей копией `get_ipv6_status_code` и не переведённым на `ui_*`
оформлением — проверка `checks/ui.sh` его поэтому и не покрывала. Отключение
теперь спрашивает подтверждение, если админ подключён по IPv6: sysctl оборвёт
эту же сессию.

## `menus/awg.sh` — AmneziaWG 3.0

```
шапка   статус ПО ФАКТУ: запущен / порт не слушает / перезапускался N раз,
        отдельной строкой форвардинг — его отсутствие ничем другим не видно
1 awg_install        выбор версии 2.0 / 3.0, затем stacks/awg.sh --mode install;
                     профиль мимикрии спрашивается только для 3.0 — пакета I1,
                     который он описывает, в 2.0 нет; повтор требует
                     ПЕРЕУСТАНОВИТЬ
2 awg_clients        список пиров, выдача конфига (адрес сервера спрашивается)
3 awg_check_updates  три поверхности: оба образа по Docker-Content-Digest
                     и релиз awg-tool; версии не фиксирует, только сообщает
4 журнал сервера
5 awg_uninstall      УДАЛИТЬ; снимает контейнеры, сеть, тома, правило UFW
                     и запись форвардинга
```
