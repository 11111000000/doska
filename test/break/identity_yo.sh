#!/bin/sh
# Отрицательный контроль для claim'а identity-resolution.
#
# Что ломает: нормализацию «ё» → «е». Правка убирает замену, поэтому
# «Пётр» перестаёт совпадать с «петр», и нераспознанное имя теряется
# вместо заглушки.
#
# Ожидание: verifier (тесты идентичности) после этой правки падает.
set -eu

file=src/identity/resolve.ml
before='let s = replace_yo s in'
after='let s = s in'

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
