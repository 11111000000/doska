#!/bin/sh
# Отрицательный контроль для claim'а api-actor-required.
#
# Что ломает: обязательность аутентификации. Правка переводит «нет токена»
# (401) в «правило запрещает» (403), поэтому клиент не может отличить
# «я не представился» от «мне запретили» — а это разные ситуации.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/server.ml
before='(Errors.make Errors.Unauthorized
               "нет токена: пришлите Authorization: Bearer'
after='(Errors.make Errors.Forbidden
               "нет токена: пришлите Authorization: Bearer'

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
