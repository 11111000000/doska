#!/bin/sh
# Отрицательный контроль для claim'а api-release-pool.
#
# Что ломает: отпуск возвращает задачу в пул — статус снова todo, исполнитель
# снят. Правка оставляет исполнителя на месте: задача формально свободна, но
# в списке «мои» она остаётся у того, кто её отпустил, и никто её не возьмёт.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='                        ~status:Status.Todo ~assignee:(Some None) ~version ~note'
after='                        ~status:Status.Todo ~assignee:None ~version ~note'

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
