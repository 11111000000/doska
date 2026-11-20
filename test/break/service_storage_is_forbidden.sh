#!/bin/sh
# Отрицательный контроль для claim'а service-failure-types.
#
# Что ломает: сбой хранилища выдаётся за запрет правила. Клиент получает
# «правило запрещает» там, где на самом деле сломалось у нас: он не будет
# искать решение и не повторит запрос.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/api/errors.ml
before='  | Service.Failure.Storage { message } -> make Internal message'
after='  | Service.Failure.Storage { message } -> make Forbidden message'

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
