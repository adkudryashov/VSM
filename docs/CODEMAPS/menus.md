<!-- Generated: 2026-08-05 | Файлов просканировано: 9 | Оценка: ~900 токенов -->

# Карта меню

Аналог маршрутов: пункт → функция → что вызывает. Нумерация совпадает с экраном.

## Главное меню — `vsm` (319 строк)

```
1 → menu_xui.sh          6 → ipv6-menu
2 → menu_telemt.sh       7 → menu_utils.sh
3 → menu_bots.sh         8 → git pull + ln -sf + exec (обновление)
4 → menu_tests.sh        X → выход в оболочку
5 → menu_setup.sh
```

Шапка: характеристики сервера, гео (curl с таймаутом 2/4 с), статусы трёх
подсистем, блок АДРЕС без секретов.

## Управление X-UI — `menu_xui.sh` (335 строк)

```
1 install_xui_pro        xui_installer_fetch: отпечаток + снятие check_cpu;
                       оба домена обязательны, автоопределения больше нет
2 patch_xui_pro          отпечаток + run_remote_script x-ui-patch.sh
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

## Стек telemt — `menu_telemt.sh` (898 строк)

```
УСТАНОВКА
1 run_install full     СТЕРЕТЬ → telemt-stack.sh --mode full
2 run_install addon    → telemt-stack.sh --mode addon

ЭКСПЛУАТАЦИЯ
3 run_diagnostics      службы, порты, HTTP-коды, сквозной self-SNI тест
4 restore_mask         nginx_mask_apply + panel_proxy_localize + panel_proxy_apply
                       + panel_proxy_verify; здесь же миграция старых установок
5 check_tls_parity     отпечаток / протокол / шифр / группа / ALPN + PQ
6 show_credentials     telemt-credentials.txt, адрес панели подставляется живой
7 manage_services      telemt, telemt-panel

ДОПОЛНИТЕЛЬНО
8  run_mtproxyl        сторонний лимитер, режим Reanimator
9  run_rebuild_nginx   rebuild-nginx-openssl35.sh, 20–40 минут; читает rc и
                       печатает фактическое состояние nginx/telemt/telemt-panel
10 uninstall_stack     УДАЛИТЬ; снимает блок панели и ACL на ключ LE
```

## Telegram-боты — `menu_bots.sh` (343 строки)

```
1 combined   3xui-telemt-bot     ─┐
2 both       telemt-bot + 3xui-monitor │ взаимоисключающие,
3 telemt     telemt-bot          │ stop_unit снимает лишние
4 3xui       3xui-monitor        ─┘
5 run_update   git reset --hard + pip + restart
6 show_settings
7 управление службами
8 run_remove   УДАЛИТЬ; снимает карту из nginx и /var/www/telemt-map
```

Все четыре режима вызывают `bots-stack.sh --bots <режим>`.

## Настройка — `menu_setup.sh` (554 строки)

```
1 show_bbr_menu     enable_bbr / disable_bbr, sysctl.conf
2 show_ping_menu    manage_ping_logic, правит /etc/ufw/before.rules
3 show_ufw_menu     ufw_enable_safely — разрешает SSH ДО включения
4 set_timezone_menu
5 manage_ssl_menu   certbot --standalone; trap INT TERM HUP → restore_stopped_services
6 menu_warp.sh
```

`ufw_enable_safely` объединяет источники SSH-порта: `$SSH_CONNECTION`,
`sshd -T`, `sshd_config.d`, `ss`. Порт панели наружу не открывает.

## Прочее

- `menu_tests.sh` (261) — IP region, доступность из РФ, iPerf3, YABS, IPQuality, sysbench, RealiTLScanner, DPI Detector, SNI Scan
- `menu_utils.sh` (190) — htop, ncdu, nethogs, внешний IP, ping/mtr, порты, kill, очистка, проверка домена
- `menu_warp.sh` (256) — Cloudflare WARP в режиме SOCKS5
- `ipv6-menu` (122) — вкл/выкл в текущей сессии + автозагрузка через sysctl.conf
