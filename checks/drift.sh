#!/bin/bash

# ======================================================================
# ПРОВЕРКА ДРЕЙФА: сверка действительности с реестром решений VSM.
#
# Реестр и объяснение, зачем он нужен, — в lib/expectations.sh.
#
#   bash checks/drift.sh              проверить, починить класс fix, показать
#   bash checks/drift.sh --dry-run    только показать, ничего не трогать
#   bash checks/drift.sh --json       машинный вывод для сторожа в боте
#
# Проверка целиком локальная: читаются файлы и состояние служб, наружу не
# уходит ни одного пакета.
# ======================================================================

set -uo pipefail

VSM_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# shellcheck source=/dev/null
for _lib in nginx_mask.sh nginx_panel_proxy.sh nginx_mtpl_proxy.sh panels.sh expectations.sh; do
    [ -r "$VSM_ROOT/lib/$_lib" ] && . "$VSM_ROOT/lib/$_lib"
done

if ! declare -p EXPECTATIONS >/dev/null 2>&1; then
    echo "Не найден lib/expectations.sh — переустановите VSM: bash install.sh" >&2
    exit 2
fi

MODE="human"
DO_FIX=1
for arg in "$@"; do
    case "$arg" in
        --json)    MODE="json" ;;
        --dry-run) DO_FIX=0 ;;
        -h|--help) sed -n '3,15p' "$(readlink -f "${BASH_SOURCE[0]}")"; exit 0 ;;
    esac
done

# Позиции, у которых ожидание — не константа, а запомненная база сравнения.
# Первый прогон её запоминает молча: объявлять дрейфом то, с чем мы ещё не
# сравнивали, — верный способ начать со ста ложных срабатываний.
_is_baseline() { case "$1" in foreign_timers|sudoers_grants) return 0 ;; *) return 1 ;; esac; }

_json_str() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' \
        | tr -d '\000-\037'
}

RESULTS=()   # id|класс|статус|заголовок|почему|стало|должно
DRIFT=0
FIXED=0

for entry in "${EXPECTATIONS[@]}"; do
    IFS='|' read -r id class title why <<< "$entry"

    if expect_excluded "$id"; then
        RESULTS+=("$id|$class|исключено|$title|$why||")
        continue
    fi
    if ! "applies_$id" 2>/dev/null; then
        RESULTS+=("$id|$class|нет компонента|$title|$why||")
        continue
    fi

    actual="$("read_$id" 2>/dev/null)"
    want="$("want_$id" 2>/dev/null)"

    if _is_baseline "$id" && [ -z "$want" ]; then
        _state_set "$id" "$actual"
        RESULTS+=("$id|$class|запомнено|$title|$why|$actual|$actual")
        continue
    fi

    if [ "$actual" = "$want" ]; then
        RESULTS+=("$id|$class|в порядке|$title|$why|$actual|$want")
        continue
    fi

    # Расхождение.
    if [ "$class" = "fix" ] && [ "$DO_FIX" -eq 1 ]; then
        was="$actual"
        if "fix_$id" >/dev/null 2>&1; then
            # По факту, а не по коду возврата: функция починки могла отработать
            # без ошибки и всё равно не изменить того, что нужно.
            actual="$("read_$id" 2>/dev/null)"
        fi
        if [ "$actual" = "$want" ]; then
            FIXED=$((FIXED + 1))
            RESULTS+=("$id|$class|починено|$title|$why|$was|$want")
        else
            DRIFT=$((DRIFT + 1))
            RESULTS+=("$id|$class|починить не удалось|$title|$why|$actual|$want")
        fi
        continue
    fi

    DRIFT=$((DRIFT + 1))
    RESULTS+=("$id|$class|расхождение|$title|$why|$actual|$want")
done

# ----------------------------------------------------------------------
if [ "$MODE" = "json" ]; then
    printf '{"generated_at":%s,"drift":%s,"fixed":%s,"items":[' \
        "$(date +%s)" "$DRIFT" "$FIXED"
    first=1
    for row in "${RESULTS[@]}"; do
        IFS='|' read -r id class status title why actual want <<< "$row"
        case "$status" in "в порядке"|"нет компонента") continue ;; esac
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"id":"%s","class":"%s","status":"%s","title":"%s","why":"%s","actual":"%s","want":"%s"}' \
            "$(_json_str "$id")" "$(_json_str "$class")" "$(_json_str "$status")" \
            "$(_json_str "$title")" "$(_json_str "$why")" \
            "$(_json_str "$actual")" "$(_json_str "$want")"
    done
    printf ']}\n'
    exit 0
fi

echo
echo "СВЕРКА С РЕЕСТРОМ РЕШЕНИЙ VSM"
echo "──────────────────────────────────────────────────────────────"
for row in "${RESULTS[@]}"; do
    IFS='|' read -r id class status title why actual want <<< "$row"
    case "$status" in
        "в порядке")      printf '  ✓  %s\n' "$title" ;;
        "нет компонента") printf '  ·  %s — компонент не установлен\n' "$title" ;;
        "исключено")      printf '  ·  %s — отключено вами в %s\n' "$title" "$EXPECT_LOCAL" ;;
        "запомнено")      printf '  ·  %s — запомнено для сравнения\n' "$title" ;;
        "починено")
            printf '  ⟳  %s\n     было: %s → стало: %s\n     почему: %s\n' \
                "$title" "${actual:-пусто}" "$want" "$why" ;;
        *)
            printf '  ✗  %s\n     стало: %s   должно: %s\n     почему: %s\n' \
                "$title" "${actual:-пусто}" "$want" "$why" ;;
    esac
done
echo "──────────────────────────────────────────────────────────────"
if [ "$FIXED" -gt 0 ]; then
    echo "  Починено молча: $FIXED. Резервные копии — рядом с файлами, *.vsm-before-drift"
fi
if [ "$DRIFT" -gt 0 ]; then
    echo "  Требует вашего решения: $DRIFT"
    echo "  Блоки nginx возвращаются пунктом 4 «Восстановить nginx» в меню telemt."
    echo "  Отключить любую позицию: её id строкой в $EXPECT_LOCAL"
    exit 1
fi
[ "$FIXED" -eq 0 ] && echo "  Расхождений нет."
exit 0
