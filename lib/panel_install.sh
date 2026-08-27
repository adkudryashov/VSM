#!/bin/bash

# ======================================================================
# УСТАНОВКА telemt_panel — ОДНА НА ДВА ВЫЗЫВАЮЩИХ
#
# Раньше эти семьдесят строк жили внутри stacks/telemt.sh как этапы 4 и 5, и
# попасть в них можно было единственным путём — установкой ВСЕГО стека с нуля.
# То есть: сняли панель (а её снимает страж исключительности перед установкой
# MTProxyL) — и вернуть её нечем. Только переустановкой стека, которая стирает
# 3x-ui вместе с базой, инбаундами и всеми пользователями.
#
# Владелец сформулировал это прямо: хочу иметь возможность ставить или
# telemt_panel, или MTProxyL-Panel. Правило «одна панель на сервер» такой выбор
# и подразумевало, но выбирать было нечем: одна ставилась сама и только в
# составе стека, вторая — чужой командой мимо VSM.
#
# Поэтому установка вынесена сюда. Стек зовёт её этапом 4, меню — пунктом
# «Веб-панель». Копий не делаем принципиально: ровно так разошлись две копии
# wait_for_apt, и разошлись в опасную сторону — одна ждала, другая молча нет.
#
# ВОЗВРАЩАЕТ КОД, А НЕ УМИРАЕТ. Внутри стека уместен die, внутри меню — нет:
# упавшая функция не должна уносить с собой интерактивное меню. Вызывающий сам
# решает, что делать с единицей.
# ======================================================================

TELEMT_PANEL_INSTALLER_URL="${TELEMT_PANEL_INSTALLER_URL:-https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh}"

_pi_log()  { echo -e "${GREEN:-}  ▸${NC:-} $*"; }
_pi_warn() { echo -e "${YELLOW:-}  !${NC:-} $*"; }
_pi_err()  { echo -e "${RED:-}  ✗${NC:-} $*" >&2; }

# Ждём готовности, а не спим наугад: панель поднимается за разное время на
# разном железе, и фиксированный sleep либо тратит время впустую, либо не
# дожидается.
_pi_wait_until() {
    local limit="$1"; shift
    local i=0
    while [ "$i" -lt "$limit" ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# ----------------------------------------------------------------------
# panel_install_telemt <логин> <пароль> <порт> <домен-панели> <домен-reality> <префикс>
#
# Ставит telemt_panel, переводит её на loopback без своего TLS и подключает к
# 443 домена панели по секретному префиксу. Проверяет фактом на каждом шаге.
# ----------------------------------------------------------------------
panel_install_telemt() {
    local admin_user="$1" admin_pass="$2" port="$3"
    local domain_panel="$4" domain_reality="$5" prefix="$6"

    local need fn
    for fn in panel_proxy_localize panel_proxy_apply panel_proxy_verify \
              nginx_mask_panel_vhost; do
        declare -F "$fn" >/dev/null 2>&1 || need="${need} $fn"
    done
    if [ -n "$need" ]; then
        _pi_err "не подключены библиотеки nginx:${need}"
        return 1
    fi

    command -v script >/dev/null 2>&1 || {
        _pi_err "нужен script(1) из util-linux — через него установщику выдаётся псевдотерминал."
        return 1
    }

    local installer
    installer="$(mktemp /tmp/telemt-panel-install.XXXXXX.sh)" || return 1

    if ! curl -fsSL "$TELEMT_PANEL_INSTALLER_URL" -o "$installer" || [ ! -s "$installer" ]; then
        rm -f "$installer"
        _pi_err "не удалось скачать установщик telemt_panel."
        return 1
    fi

    # Порядок вопросов установщика: API URL, auth header, admin user,
    # admin password, путь к бинарнику telemt, имя systemd-юнита.
    # Пустая строка = дефолт.
    #
    # "stty -echo" плюс пауза перед подачей ответов — против утечки пароля.
    # Строчная дисциплина псевдотерминала отражает всё поданное на вход СРАЗУ по
    # приходу, задолго до того, как установщик доберётся до своего prompt_secret
    # и сам погасит эхо; без этого пароль админа уходит в stdout открытым
    # текстом и оседает в любом логе, куда перенаправлен вывод. Пауза нужна,
    # чтобы stty успел отработать раньше, чем script нальёт ответы в терминал.
    # Если паузы всё же не хватит, установка не сломается — вернётся прежнее
    # поведение с эхом.
    _pi_log "запускаю установщик telemt_panel..."
    { sleep 2; printf '\n\n%s\n%s\n\n\n' "$admin_user" "$admin_pass"; } \
        | script -qe -c "stty -echo 2>/dev/null; bash '$installer'" /dev/null
    rm -f "$installer"

    local toml=/etc/telemt-panel/config.toml
    [ -f "$toml" ] || { _pi_err "telemt_panel не создала $toml."; return 1; }

    # Панель слушает ТОЛЬКО loopback и без своего TLS.
    #
    # Раньше было 0.0.0.0 плюс собственный сертификат домена REALITY, и снаружи
    # это выглядело как админ-форма с валидным сертификатом на нестандартном
    # порту — самый громкий объект на сервере. Сканеру хватало одного
    # соединения, чтобы классифицировать IP, и работа по маскировке порта telemt
    # после этого теряла смысл. Теперь TLS терминирует nginx на 443 домена
    # панели, а попасть внутрь можно по случайному префиксу пути.
    panel_proxy_localize "$toml" "$port" "$domain_reality" || {
        _pi_err "не удалось перевести telemt_panel на loopback (причина выше)."
        return 1
    }
    systemctl is-active --quiet telemt-panel || {
        _pi_err "служба telemt-panel не запустилась — journalctl -u telemt-panel"
        return 1
    }

    # Обращаемся по http: TLS у панели больше нет.
    _pi_wait_until 20 curl -s --max-time 5 "http://127.0.0.1:${port}/" -o /dev/null \
        || _pi_warn "telemt_panel не отвечает на http://127.0.0.1:${port}/ — journalctl -u telemt-panel"
    local code
    code="$(curl -s --max-time 10 "http://127.0.0.1:${port}/" -o /dev/null -w '%{http_code}')" || code=000
    [ "$code" = "200" ] || _pi_warn "telemt_panel вернула $code вместо 200 — journalctl -u telemt-panel"

    # Подключаем панель к 443 домена панели по случайному префиксу пути.
    #
    # Блок вписывается в vhost панели, а тот лежит в sites-enabled — каталоге,
    # который установщик и патч 3x-ui-pro вычищают целиком. Пережить это он, в
    # отличие от маски, не может: nginx не умеет добавлять location в чужой
    # server{} из отдельного файла. Поэтому блок помечен маркерами и
    # переприменяется пунктом меню «Восстановить nginx».
    _pi_log "подключаю панель к 443 домена ${domain_panel}"
    local vhost
    vhost="$(nginx_mask_panel_vhost "$domain_panel")" || {
        _pi_err "не найден vhost домена ${domain_panel} — панель некуда подключить."
        return 1
    }
    panel_proxy_apply "$vhost" "$prefix" "$port" || {
        _pi_err "не удалось подключить telemt_panel к nginx (причина выше)."
        return 1
    }

    local url_check
    if url_check="$(panel_proxy_verify "$domain_panel" "$prefix")"; then
        _pi_log "панель отвечает по своему адресу"
    else
        _pi_warn "панель по адресу через nginx вернула ${url_check} — проверьте вручную."
        _pi_warn "если вёрстка поедет, панель не умеет работать из подкаталога: тогда"
        _pi_warn "оставьте её на loopback и ходите через ssh -L ${port}:127.0.0.1:${port}"
    fi
    return 0
}
