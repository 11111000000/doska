#!/bin/sh
# Отрицательный контроль для claim'а api-link-kind.
#
# Что ломает: вид связи — из закрытого перечня, неизвестное имя — ошибка
# запроса. Правка принимает любое имя как обычную связь, и опечатка клиента
# тихо становится связью другого смысла.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/tasks.ml
before='          | None -> bad_request ("неизвестный вид связи: " ^ kind_name)'
after='          | None ->
              answer
                (Service.Task.link conn ~actor ~interface_:Interface.Api ~ref_ ~to_ref
                   ~kind:Link.Relates_to)
                (fun link -> created (`Assoc [ ("link", View.link link) ]))'

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
