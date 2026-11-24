#!/bin/sh
# Отрицательный контроль для claim'а overview-wip-order.
#
# Что ломает: порядок нагрузки перестаёт отвечать на вопрос «кто завален».
# Правка убирает сортировку по числу задач — список идёт по логину, и человек
# с тремя задачами оказывается выше человека с двадцатью.
#
# Ожидание: verifier (test/service_overview_test.exe) после этой правки падает.
set -eu

file=src/db/repo_overview.ml
before='        ORDER BY count(*) DESC, a.handle) x"'
after='        ORDER BY a.handle) x"'

python3 - "$file" "$before" "$after" <<'PY'
import pathlib, sys

path, before, after = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
count = text.count(before)
if count != 1:
    sys.exit(f"правка не применилась: {before!r} встречается {count} раз в {path}, нужен 1")
p.write_text(text.replace(before, after), encoding="utf-8")
PY
