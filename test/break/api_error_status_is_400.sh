#!/bin/sh
# Отрицательный контроль для claim'а api-error-contract.
#
# Что ломает: соответствие кода ответа классу ошибки. Правка переводит
# «правило запрещает» (403) в «запрос неправильный» (400), поэтому клиент
# больше не может отличить запрет домена от своей ошибки — ровно то, чего
# единый формат ошибок обещать не должен.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/errors.ml
before='  | Forbidden -> `Forbidden'
after='  | Forbidden -> `Bad_Request'

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
