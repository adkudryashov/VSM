#!/bin/bash

# ======================================================================
# ДОСТУП К telemt_panel ЧЕРЕЗ 443 ДОМЕНА ПАНЕЛИ
#
# Сорсится теми же двумя потребителями, что и _nginx_mask.sh:
# telemt-stack.sh (set -euo pipefail, свои log/warn/die) и menu_telemt.sh
# (интерактивное меню без set -e). Поэтому здесь нет ни цветов, ни read, ни
# exit, а ветвления записаны полной формой if/fi: голое "[ -n "$x" ] && cmd"
# под set -e роняет вызывающего.
#
# ЗАЧЕМ. Раньше telemt_panel слушала 0.0.0.0:9444 и сама терминировала TLS
# сертификатом домена REALITY. Снаружи это выглядело как админ-форма с валидным
# сертификатом на нестандартном порту — самый громкий объект на сервере:
# сканеру хватало одного соединения, чтобы классифицировать IP, и вся работа по
# маскировке порта telemt после этого теряла смысл.
#
# Теперь панель слушает только 127.0.0.1, TLS терминирует nginx тем же
# сертификатом, что и сайт панели, а попасть внутрь можно по случайному
# префиксу пути на обычном 443. Снаружи новых портов нет вовсе. Ровно так же
# устроена сама 3x-ui: она живёт по случайному webBasePath на том же 443.
#
# Побочно снимается отдельная проблема: панели больше не нужен доступ к
# приватному ключу Let's Encrypt, ради которого ей выдавался ACL на
# /etc/letsencrypt. Процесс, смотрящий в интернет, ключ больше не читает.
#
# ГДЕ ЖИВЁТ. В отличие от маски, этот блок нельзя положить в conf.d: nginx не
# умеет добавлять location в чужой server{} из отдельного файла. Значит, правим
# vhost панели в sites-enabled — а его установщик и патч 3x-ui-pro вычищают
# целиком. Поэтому блок помечен маркерами и переприменяется тем же пунктом
# меню, который восстанавливает маску. Ту же природу имеет предупреждение
# warn_telemt_after_panel_change в меню X-UI.
# ======================================================================

PANEL_PROXY_BEGIN="# >>> VSM telemt_panel proxy — не редактируй вручную"
PANEL_PROXY_END="# <<< VSM telemt_panel proxy"

# ----------------------------------------------------------------------
# Случайный префикс пути. Печатает значение в stdout.
#
# 32 hex-символа: угадать перебором нельзя, а путь не попадает ни в
# сертификаты, ни в CT-логи, ни в DNS — в отличие от домена, который сканер
# получает бесплатно.
# ----------------------------------------------------------------------
panel_proxy_gen_prefix() {
    openssl rand -hex 16
}

# ----------------------------------------------------------------------
# Текст блока в stdout.
#
# proxy_pass со слэшем на конце: nginx срежет префикс, и панель увидит запрос
# от корня. Это единственный способ отдать её из подкаталога, не полагаясь на
# поддержку X-Forwarded-Prefix, которой у неё может не быть.
# ----------------------------------------------------------------------
panel_proxy_render() {
    local prefix="$1" port="$2"

    cat << EOF
${PANEL_PROXY_BEGIN}
    location /${prefix}/ {
        proxy_pass http://127.0.0.1:${port}/;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # Панель обновляет статистику через WebSocket/SSE — без этих двух строк
        # соединение рвётся по таймауту, и графики замирают без ошибки.
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 3600s;
    }
${PANEL_PROXY_END}
EOF
}

# ----------------------------------------------------------------------
# Убирает прежний блок VSM из текста vhost (stdin -> stdout).
# Нужен и при переустановке, и при удалении стека.
# ----------------------------------------------------------------------
panel_proxy_strip() {
    awk -v b="$PANEL_PROXY_BEGIN" -v e="$PANEL_PROXY_END" '
        index($0, b) { skip=1 }
        !skip { print }
        index($0, e) { skip=0 }
    '
}

# ----------------------------------------------------------------------
# Вписывает блок в server{}, где есть ssl_certificate — перед его закрывающей
# скобкой. Ищем именно TLS-блок: в типовом vhost «80 → редирект на 443» сверху
# лежит блок порта 80, и попасть туда значило бы отдавать панель по http.
#
# Печатает изменённый текст в stdout. Возвращает 1, если подходящий блок не
# найден, — вызывающий тогда не станет ничего записывать.
# ----------------------------------------------------------------------
panel_proxy_insert() {
    local block="$1"
    awk -v block="$block" '
        BEGIN { depth=0; buf=""; done=0 }
        {
            lines[NR] = $0
            if (!done) {
                if ($0 ~ /^[[:space:]]*server[[:space:]]*\{/ && depth==0) {
                    depth=1; start=NR; found=0; next
                }
                if (depth>0) {
                    if ($0 ~ /ssl_certificate[[:space:]]/ && $0 !~ /^[[:space:]]*#/) found=1
                    depth += gsub(/\{/,"{")
                    depth -= gsub(/\}/,"}")
                    if (depth<=0) {
                        if (found) { close_at=NR; done=1 }
                        depth=0
                    }
                }
            }
        }
        END {
            if (!done) exit 1
            for (i=1; i<=NR; i++) {
                if (i==close_at) print block
                print lines[i]
            }
        }
    '
}

# ----------------------------------------------------------------------
# Полный цикл: снять прежний блок, вставить новый, проверить и перезагрузить
# nginx с откатом при неудаче.
#
# 0 — применено; 1 — не применено, причина в stderr.
# ----------------------------------------------------------------------
panel_proxy_apply() {
    local vhost="$1" prefix="$2" port="$3"
    local backup="${vhost}.vsm-bak" content

    if [ ! -f "$vhost" ]; then
        echo "не найден vhost панели: $vhost" >&2
        return 1
    fi
    if ! printf '%s' "$prefix" | grep -qE '^[A-Za-z0-9_-]+$'; then
        echo "недопустимый префикс пути панели: '$prefix'" >&2
        return 1
    fi
    if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        echo "нужен числовой порт telemt_panel (получено '$port')" >&2
        return 1
    fi

    content="$(panel_proxy_strip < "$vhost" | panel_proxy_insert "$(panel_proxy_render "$prefix" "$port")")" || {
        echo "в $vhost не найден server{} с ssl_certificate — панель некуда подключить" >&2
        return 1
    }

    cp -p "$vhost" "$backup" || { echo "не удалось сохранить копию $vhost" >&2; return 1; }

    if ! printf '%s\n' "$content" > "$vhost"; then
        echo "не удалось записать $vhost" >&2
        mv -f "$backup" "$vhost"
        return 1
    fi

    if nginx -t; then
        rm -f "$backup"
        if ! systemctl reload nginx; then
            echo "конфиг принят nginx -t, но systemctl reload nginx не сработал" >&2
            return 1
        fi
        return 0
    fi

    mv -f "$backup" "$vhost"
    if nginx -t >/dev/null 2>&1; then
        echo "конфиг с блоком telemt_panel отклонён nginx -t, изменения откачены" >&2
    else
        echo "nginx -t не проходит и ПОСЛЕ отката — ошибка не в этом блоке" >&2
    fi
    return 1
}

# ----------------------------------------------------------------------
# Серверная половина переезда: панель на loopback, свой TLS снят, порт закрыт,
# доступ к приватному ключу отозван.
#
# Вынесено сюда, а не оставлено в установщике, потому что переезжать должны и
# уже установленные серверы — через пункт «Восстановить конфиги nginx». Пока
# этого не было, пункт применял только блок nginx: панель продолжала слушать
# 0.0.0.0 и говорить по HTTPS, а nginx шёл к ней по http:// и получал 400.
# На стенде это выглядело как 404, потому что vhost 3x-ui-pro переписывает
# любую ошибку апстрима в 404 (error_page ... =404 + proxy_intercept_errors).
#
# 0 — панель переведена; 1 — не удалось (причина в stderr).
# ----------------------------------------------------------------------
panel_proxy_localize() {
    local toml="$1" port="$2" domain_reality="$3"

    if [ ! -f "$toml" ]; then
        echo "не найден конфиг панели: $toml" >&2
        return 1
    fi
    if ! printf '%s' "$port" | grep -qE '^[0-9]+$'; then
        echo "нужен числовой порт панели (получено '$port')" >&2
        return 1
    fi

    sed -i "s|^listen = .*|listen = \"127.0.0.1:${port}\"|" "$toml"
    if ! grep -q "^listen = \"127.0.0.1:${port}\"" "$toml"; then
        echo "не удалось задать listen в $toml — проверь формат файла у автора панели" >&2
        return 1
    fi

    # Секция [tls] больше не нужна: TLS терминирует nginx. Удаляем от строки
    # [tls] до следующей секции или конца файла.
    if grep -q '^\[tls\]' "$toml"; then
        sed -i '/^\[tls\]/,/^\[/{ /^\[tls\]/d; /^cert_file/d; /^key_file/d; }' "$toml"
    fi

    systemctl restart telemt-panel 2>/dev/null || true

    # Доступ к приватному ключу Let's Encrypt панели больше не нужен.
    if id telemt-panel >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
        setfacl -x u:telemt-panel /etc/letsencrypt/live /etc/letsencrypt/archive 2>/dev/null || true
        if [ -n "$domain_reality" ]; then
            setfacl -R -x u:telemt-panel "/etc/letsencrypt/archive/${domain_reality}" 2>/dev/null || true
        fi
    fi

    # Порт наружу закрываем: панель теперь только на loopback.
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
    return 0
}

# ----------------------------------------------------------------------
# Проверка ФАКТОМ, а не кодом возврата применения конфига.
#
# nginx принял конфиг — это ещё не значит, что панель отвечает. Прежняя версия
# печатала «Панель доступна» сразу после panel_proxy_apply и врала.
#
# Печатает полученный HTTP-код в stdout. 0 — панель отвечает осмысленно.
# ----------------------------------------------------------------------
panel_proxy_verify() {
    local domain="$1" prefix="$2" code
    code="$(curl -sk --max-time 10 --resolve "${domain}:443:127.0.0.1" \
        "https://${domain}/${prefix}/" -o /dev/null -w '%{http_code}' 2>/dev/null)" || code=000
    printf '%s' "$code"
    case "$code" in
        200|301|302|307|308) return 0 ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------------
# Снятие блока: при удалении стека. Молчит, если блока и не было.
# ----------------------------------------------------------------------
panel_proxy_remove() {
    local vhost="$1" content
    [ -f "$vhost" ] || return 0
    grep -qF "$PANEL_PROXY_BEGIN" "$vhost" || return 0

    content="$(panel_proxy_strip < "$vhost")"
    cp -p "$vhost" "${vhost}.vsm-bak" || return 1
    if ! printf '%s\n' "$content" > "$vhost"; then
        mv -f "${vhost}.vsm-bak" "$vhost"
        return 1
    fi
    if nginx -t; then
        rm -f "${vhost}.vsm-bak"
        systemctl reload nginx >/dev/null 2>&1
        return 0
    fi
    mv -f "${vhost}.vsm-bak" "$vhost"
    return 1
}
