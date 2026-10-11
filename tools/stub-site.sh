#!/bin/bash
# Сайт-заглушка VSM из командной строки и таймера vsm-stub-site.
#   stub-site.sh apply     собрать и выложить (прежняя страница — в копию)
#   stub-site.sh new       то же, но с новым случайным числом
#   stub-site.sh refresh   пересобрать, только если стоит наш сайт (таймер)
#   stub-site.sh state     наш сайт / чужая страница / нет страницы
#   stub-site.sh restore   вернуть страницу, стоявшую до нас
# Разбор — lib/stub_site.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck source=../lib/stub_site.sh
. "$ROOT/lib/stub_site.sh"

case "${1:-}" in
    apply)   stub_site_apply ;;
    new)     stub_site_apply new ;;
    refresh) stub_site_refresh ;;
    state)   stub_site_state ;;
    restore) stub_site_restore ;;
    *) echo "использование: $0 apply|new|refresh|state|restore" >&2; exit 2 ;;
esac
