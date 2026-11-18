#!/bin/sh
# Отрицательный контроль для claim'а db-value-escaping.
#
# Что ломает: экранирование значений, попадающих в SQL. Правка перестаёт
# удваивать одинарную кавычку, поэтому значение с кавычкой ломает запрос —
# а это ровно то, что экранирование и должно было поймать (решение этапа 1:
# SQL собирается из проверенных значений и экранируется Conn.quote).
#
# Ожидание: verifier (test/repo_test.exe) после этой правки падает.
set -eu

file=src/db/conn.ml
before="if c = '\\'' then Buffer.add_string b \"''\""
after="if c = '\\'' then Buffer.add_char b c"

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
