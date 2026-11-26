#!/bin/sh
# Отрицательный контроль для claim'а api-link-cycle.
#
# Что ломает: в графе блокировок не может быть кольца — иначе «кто мешает»
# превращается в «все мешают всем». Правка ищет путь в обратную сторону, и
# кольцо записывается: «X мешает Y» и «Y мешает X» одновременно.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='      let* chain = blocking_chain conn ~visited:[] ~chain:[ v ] v u in'
after='      let* chain = blocking_chain conn ~visited:[] ~chain:[ v ] u v in'

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
