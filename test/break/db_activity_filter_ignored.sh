#!/bin/sh
# Отрицательный контроль для claim'а db-activity-filters.
#
# Что ломает: выборку журнала по задаче. Правка убирает условие «событие этой
# задачи» — фильтр становится условием, истинным всегда, поэтому в выборку
# попадают чужие события (P4, §3.6).
#
# Ожидание: verifier (test/repo_test.exe) после этой правки падает.
set -eu

file=src/db/repo_activity.ml
before='  | Some t -> add (Printf.sprintf "t.ref = %s" (Conn.quote t))'
after='  | Some t -> add (Printf.sprintf "%s IS NOT NULL" (Conn.quote t))'

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
