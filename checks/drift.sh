#!/bin/bash

# ======================================================================
# ПРОВЕРКА ДРЕЙФА: сверка действительности с реестром решений VSM.
#
# Реестр и объяснение, зачем он нужен, — в lib/expectations.sh.
#
#   bash checks/drift.sh              проверить, починить класс fix, показать
#   bash checks/drift.sh --dry-run    только показать, ничего не трогать
#   bash checks/drift.sh --json       машинный вывод для сторожа в боте
#   bash checks/drift.sh --accept ID  принять нынешнее как новую норму
#   bash checks/drift.sh --accept-all принять все позиции с базой сравнения
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
ACCEPT_IDS=()
ACCEPT_ALL=0
# Справку печатаем до первой НЕ-комментарной строки, а не диапазоном номеров.
# Прежде здесь стоял sed -n '3,15p', и любая новая строка в шапке молча
# обрезала последнюю: справка врала бы ровно на то, что в неё добавили.
_help() { awk 'NR > 2 && /^#/ { print; next } NR > 2 { exit }' \
    "$(readlink -f "${BASH_SOURCE[0]}")"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --json)       MODE="json" ;;
        --dry-run)    DO_FIX=0 ;;
        --accept-all) ACCEPT_ALL=1 ;;
        --accept)     shift; [ $# -gt 0 ] || { echo "--accept требует id позиции" >&2; exit 2; }
                      ACCEPT_IDS+=("$1") ;;
        -h|--help)    _help; exit 0 ;;
    esac
    shift
done

# Позиции, у которых ожидание — не константа, а запомненная база сравнения.
# Первый прогон её запоминает молча: объявлять дрейфом то, с чем мы ещё не
# сравнивали, — верный способ начать со ста ложных срабатываний.
_is_baseline() { case "$1" in foreign_timers|sudoers_grants) return 0 ;; *) return 1 ;; esac; }

# ----------------------------------------------------------------------
# Принять нынешнее состояние как новую норму.
#
# Без этого у владельца был ровно один выход из законного расхождения —
# отключить позицию строкой в expectations.local, то есть перестать следить
# НАВСЕГДА. А расхождения тут бывают законные: мы сами удалили панель, и права
# в sudoers.d исчезли вместе с ней; мы сами поставили MTProxyL, и она принесла
# два своих таймера. Позиция кричала бы об этом до конца времён, и первое, что
# сделал бы уставший человек, — выключил бы её. Сторож, которого выключили,
# хуже отсутствующего: он числится работающим.
#
# Принимать имеет смысл только там, где ожидание — запомненная база, а не
# константа. У остальных позиций «норма» задана решением проекта, и менять её
# правкой состояния нельзя: для этого есть исходный код и обсуждение.
# ----------------------------------------------------------------------
_accept_one() {
    local id="$1" was now
    if ! _is_baseline "$id"; then
        echo "  ✗ ${id}: у этой позиции нет базы сравнения — принимать нечего." >&2
        echo "    Норма задана решением проекта в lib/expectations.sh." >&2
        return 1
    fi
    if ! declare -F "read_$id" >/dev/null 2>&1; then
        echo "  ✗ ${id}: такой позиции в реестре нет." >&2
        return 1
    fi
    if ! "applies_$id" 2>/dev/null; then
        echo "  · ${id}: компонент не установлен, принимать нечего."
        return 0
    fi
    was="$(_state_get "$id")"
    now="$("read_$id" 2>/dev/null)"
    if [ "$was" = "$now" ]; then
        echo "  · ${id}: уже норма, ничего не менял."
        return 0
    fi
    _state_set "$id" "$now" || { echo "  ✗ ${id}: не удалось записать $EXPECT_STATE" >&2; return 1; }
    echo "  ✓ ${id}: принято."
    echo "    было:  ${was:-пусто}"
    echo "    стало: ${now:-пусто}"
    return 0
}

if [ "$ACCEPT_ALL" -eq 1 ] || [ "${#ACCEPT_IDS[@]}" -gt 0 ]; then
    if [ "$ACCEPT_ALL" -eq 1 ]; then
        ACCEPT_IDS=()
        for entry in "${EXPECTATIONS[@]}"; do
            IFS='|' read -r id _ <<< "$entry"
            _is_baseline "$id" && ACCEPT_IDS+=("$id")
        done
    fi
    echo
    echo "ПРИНЯТИЕ НОВОЙ НОРМЫ"
    echo "──────────────────────────────────────────────────────────────"
    _acc_rc=0
    for id in "${ACCEPT_IDS[@]}"; do _accept_one "$id" || _acc_rc=1; done
    echo "──────────────────────────────────────────────────────────────"
    echo "  Сверка после этого покажет эти позиции в порядке."
    exit "$_acc_rc"
fi

# Позиции, значение которых само по себе секрет.
#
# Префикс пути к панели — единственное, что закрывает её от всех, кто знает
# домен. А отчёт этой проверки не остаётся в терминале: сторож раз в час шлёт
# его в Telegram, и он же печатается в диагностике, скриншот которой ничего не
# стоит переслать. Печатать там секрет целиком — то же самое, что показывать
# его в главном меню, чего проект не делает намеренно.
#
# Сравнение идёт по ПОЛНЫМ значениям и маскировка на него не влияет: усечь их
# до сравнения значило бы проглядеть расхождение в хвосте.
_is_secret() { case "$1" in panel_prefix) return 0 ;; *) return 1 ;; esac; }

# Маскируем только то, что похоже на секрет. Позиция отдаёт сюда и обычные
# сообщения вроде «блока MTProxyL-Panel нет» — превратить их в «блока…» значит
# спрятать причину и заставить лезть на сервер за тем, что и так не секрет.
_mask_secret() {
    local v="$1"
    if printf '%s' "$v" | grep -qE '^[A-Za-z0-9_-]{12,}$'; then
        printf '%s… (%s симв.)' "${v:0:6}" "${#v}"
    else
        printf '%s' "$v"
    fi
}

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
        if _is_secret "$id"; then
            actual="$(_mask_secret "$actual")"; want="$(_mask_secret "$want")"
        fi
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
    if _is_secret "$id"; then
        actual="$(_mask_secret "$actual")"; want="$(_mask_secret "$want")"
    fi
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
    # Подсказку про принятие показываем ТОЛЬКО когда есть что принимать, и
    # ставим её ПЕРЕД подсказкой про отключение. Порядок тут не косметика:
    # человек делает то, что прочитал первым, а отключить позицию — это
    # перестать следить навсегда, тогда как принять — оставить сторожа на
    # посту с новой отметкой.
    _acc_list=""
    for row in "${RESULTS[@]}"; do
        IFS='|' read -r id _ status _ <<< "$row"
        [ "$status" = "расхождение" ] || continue
        _is_baseline "$id" && _acc_list="${_acc_list}${_acc_list:+ }${id}"
    done
    if [ -n "$_acc_list" ]; then
        echo "  Если изменение законное (сами поставили или удалили) — принять как норму:"
        echo "    bash checks/drift.sh --accept ${_acc_list// / --accept }"
    fi
    echo "  Отключить любую позицию совсем: её id строкой в $EXPECT_LOCAL"
    exit 1
fi
[ "$FIXED" -eq 0 ] && echo "  Расхождений нет."
exit 0
