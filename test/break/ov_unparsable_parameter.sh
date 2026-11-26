#!/bin/sh
# Отрицательный контроль для claim'а overview-api-parameters.
#
# Что ломает: неразобранный параметр перестаёт быть ошибкой запроса. Правка
# заменяет отказ на молчаливую подмену — клиент, передавший мусор, получает
# сводку по умолчанию и решает, что его параметр учли.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/overview.ml
before='      | None -> Error ("неизвестное значение параметра " ^ name ^ ": " ^ raw))'
after='      | None -> Ok None)'

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
