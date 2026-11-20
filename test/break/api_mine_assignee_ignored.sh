#!/bin/sh
# Отрицательный контроль для claim'а api-mine-assignee-scope.
#
# Что ломает: «мои» — это исполнитель из заголовка актора. Правка оставляет
# условие «исполнитель вообще есть», а равенство убирает: литерал uuid всегда
# не null, поэтому в выборку попадают задачи любого исполнителя, и агент видит
# чужую работу.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='            Printf.sprintf "t.assignee_id = %s" assignee;'
after='            Printf.sprintf "t.assignee_id IS NOT NULL AND %s IS NOT NULL" assignee;'

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
