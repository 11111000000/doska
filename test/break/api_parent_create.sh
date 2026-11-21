#!/bin/sh
# Отрицательный контроль для claim'а api-parent-create.
#
# Что ломает: родителя можно задать при создании, и задача сразу входит в
# ветку. Правка роняет родителя при создании, и задачи остаются сиротами:
# дерево веток не собирается, связи между работами теряются.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='      | Ok (Some task) -> Lwt_result.lift (Ok (Some task.Task.id))'
after='      | Ok (Some _task) -> Lwt_result.lift (Ok None)'

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
