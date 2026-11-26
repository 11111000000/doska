#!/bin/sh
# Отрицательный контроль для claim'а api-link-self.
#
# Что ломает: связь задачи с собой бессмысленна. Правка убирает проверку, и
# задача получает связь сама с собой — граф перестаёт быть графом, а сводка
# по связям показывает задачу, которая мешает самой себе.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='  if from_task.Task.id = to_task.Task.id then
    Lwt_result.lift (Ok (Some (bad_request "связь задачи с собой")))'
after='  if from_task.Task.id = to_task.Task.id && to_task.Task.id = "" then
    Lwt_result.lift (Ok (Some (bad_request "связь задачи с собой")))'

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
