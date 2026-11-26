#!/bin/sh
# Отрицательный контроль для claim'а overview-api-shape.
#
# Что ломает: форма ответа сводки перестаёт совпадать с объявленной. Правка
# убирает из тела ответа поле generated_at — клиент больше не знает, на какой
# момент посчитана сводка, и читает ответ, которого нет.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/overview.ml
before='      ("generated_at", `String s.Service.Overview.generated_at);'

python3 - "$file" "$before" <<'PY'
import pathlib, sys

path, before = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
needle = before + "\n"
count = text.count(needle)
if count != 1:
    sys.exit(f"правка не применилась: {before!r} встречается {count} раз в {path}, нужен 1")
p.write_text(text.replace(needle, ""), encoding="utf-8")
PY
