#!/bin/bash
set -euo pipefail

# ============================================================================
# Обновление баз GeoIP для telemt-бота.
#
# Прежняя версия не могла сообщить о неудаче в принципе, и это складывалось из
# четырёх независимых дефектов:
#
#   1. Не было set -e, а последней командой стоял echo «Обновление завершено».
#      Скрипт ВСЕГДА возвращал 0, поэтому проверка `if ! bash update_geoip.sh`
#      в bots-stack.sh была недостижима.
#   2. Вызывающий глушил вывод целиком (>/dev/null 2>&1), так что причина не
#      попадала даже на экран.
#   3. Базы качались в bots/telemt/geoip, а config.py читает bots/data/geoip —
#      то есть при любом исходе файлы оказывались не там, где их ищут. Проверка
#      «базы уже на месте» не срабатывала никогда, и ~90 МБ качались заново при
#      каждом запуске установщика.
#   4. Ссылки вели на https://git.io/... — сервис GitHub отключил в 2022 году.
#
# Итог: установщик печатал «Базы GeoIP получены» и «✅ ГОТОВО», а карта была
# пустой и страны не определялись. Здесь исправлены все четыре: путь берётся
# аргументом (по умолчанию тот, что читает config.py), любая ошибка прекращает
# работу с внятным текстом, а успех подтверждается ФАКТОМ — файл на месте,
# нужного размера и с сигнатурой MaxMind.
# ============================================================================

# Куда класть. По умолчанию — bots/data/geoip, ровно то, что ждёт config.py.
GEOIP_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/data/geoip}"

# Источник. Официальный MaxMind требует лицензионный ключ, поэтому берём
# зеркало, публикующее те же файлы релизами. Тег не фиксирован осознанно: базы
# обновляются еженедельно, и смысл именно в свежих. Если зеркало переедет,
# скрипт теперь об этом СКАЖЕТ, а не соврёт об успехе.
BASE_URL="${GEOIP_BASE_URL:-https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download}"

# City и ASN обязательны — их читает config.py. Country полезен, но без него
# бот работает, поэтому его отсутствие провалом не считаем.
REQUIRED=(GeoLite2-City.mmdb GeoLite2-ASN.mmdb)
OPTIONAL=(GeoLite2-Country.mmdb)

MIN_SIZE=$((1024 * 1024))   # меньше мегабайта — это не база, а страница ошибки

mkdir -p "$GEOIP_DIR"

# Файл базы MaxMind несёт метку формата в конце. Проверяем именно её, а не
# только размер: HTML-страница ошибки на пару мегабайт тоже «достаточно
# большая», и по размеру её от базы не отличить.
is_mmdb() {
    local f="$1" size
    [ -f "$f" ] || return 1
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$size" -ge "$MIN_SIZE" ] || return 1
    tail -c 200000 "$f" | grep -qa 'MaxMind.com' || return 1
    return 0
}

fetch_one() {
    local name="$1" tmp size
    tmp="$(mktemp "$GEOIP_DIR/.${name}.XXXXXX")"
    echo "  качаю $name ..."
    # Скачиваем во временный файл: оборванная загрузка не должна заменять
    # рабочую базу. Вывод curl не глушим — при неудаче нужна причина.
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 300 \
              -o "$tmp" "$BASE_URL/$name"; then
        rm -f "$tmp"
        echo "  ✗ не удалось скачать $name" >&2
        return 1
    fi
    if ! is_mmdb "$tmp"; then
        size=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
        echo "  ✗ $name скачался, но это не база MaxMind (получено $size б)" >&2
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$GEOIP_DIR/$name"
    echo "  ✓ $name — $(( $(stat -c %s "$GEOIP_DIR/$name") / 1024 / 1024 )) МБ"
    return 0
}

echo "Обновление баз GeoIP в $GEOIP_DIR"

failed=0
for name in "${REQUIRED[@]}"; do
    fetch_one "$name" || failed=1
done
for name in "${OPTIONAL[@]}"; do
    fetch_one "$name" || echo "  ! $name пропущен (не обязателен)"
done

if [ "$failed" -ne 0 ]; then
    echo "✗ Обязательные базы GeoIP не получены. Карта и определение стран работать не будут." >&2
    echo "  Источник: $BASE_URL" >&2
    echo "  Задать другой: GEOIP_BASE_URL=<url> bash $0" >&2
    exit 1
fi

# Последняя проверка — по факту на диске, а не по коду возврата загрузки.
for name in "${REQUIRED[@]}"; do
    is_mmdb "$GEOIP_DIR/$name" || { echo "✗ $GEOIP_DIR/$name не прошёл проверку." >&2; exit 1; }
done

echo "✓ Базы GeoIP на месте: $GEOIP_DIR"
