#!/bin/sh
# Отрицательный контроль для claim'а api-invalid-body.
#
# Что ломает: разбор тела запроса. Правка убирает перехват ошибки разбора
# JSON, поэтому битое тело падает наружу и клиент получает 500 («у нас
# сломалось») вместо 400 («твой запрос неправильный»).
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/params.ml
before='        | exception Yojson.Json_error e -> Lwt.return (Error e)'
after='        | exception Yojson.Json_error e -> raise (Yojson.Json_error e)'

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
