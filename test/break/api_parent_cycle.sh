#!/bin/sh
# Отрицательный контроль для claim'а api-parent-cycle.
#
# Что ломает: родителем нельзя назначить собственного потомка — дерево
# замкнулось бы в кольцо. Правка убирает проверку цепочки, и задача
# становится своим собственным предком: обход дерева зацикливается.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='        let* chain = parent_chain conn ~task_id:task.Task.id parent.Task.id in'
after='        let* chain = Lwt_result.lift (Ok []) in'

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
