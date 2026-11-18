#!/bin/sh
# Отрицательный контроль для claim'а domain-closed-types.
#
# Что ломает: обратимость имени варианта. Правка переименовывает статус
# «in_review» в «in-review», поэтому имя, которым вариант называется в API,
# в базе и в импорте, перестаёт разбираться обратно (§4.2).
#
# Ожидание: verifier (test/domain_types_test.exe) после этой правки падает.
set -eu

file=src/domain/status.ml
before='  | In_review -> "in_review"'
after='  | In_review -> "in-review"'

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
