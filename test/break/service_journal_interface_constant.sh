#!/bin/sh
# Отрицательный контроль для claim'а service-journal-interface.
#
# Что ломает: журнал перестаёт помнить интерфейс, через который пришло
# действие. Правка пишет в журнал константу вместо переданного значения —
# агентский вызов снова неотличим от человеческого.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='                    record_event conn ~actor ~interface_ ~task
                      ~action:Activity.Status_changed ~from_:task.Task.status'
after='                    record_event conn ~actor ~interface_:Interface.Api ~task
                      ~action:Activity.Status_changed ~from_:task.Task.status'

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
