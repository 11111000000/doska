#!/bin/sh
# Отрицательный контроль для claim'а api-link-duplicate.
#
# Что ломает: повторная связь — конфликт, а не новый факт. Правка убирает
# проверку, и клиент получает «успех» там, где факт уже записан: связи
# накапливаются, а читатель не знает, что они повторяют друг друга.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='    | Ok (Some _) ->
        Lwt_result.lift (Ok (Some (Failure.Conflict { message = "связь уже есть" })))'
after='    | Ok (Some _) -> Lwt_result.lift (Ok None)'

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
