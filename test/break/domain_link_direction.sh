#!/bin/sh
# Отрицательный контроль для claim'а domain-link-direction.
#
# Что ломает: направление блокировки однозначно — blocks означает «я мешаю
# ему», blocked_by — «ему мешаю я». Правка меняет направление у blocks, и
# «кто кому мешает» читается наоборот: блокер и заблокированный меняются
# местами.
#
# Ожидание: verifier (test/domain_test.exe) после этой правки падает.
set -eu

file=src/domain/link.ml
before='  | Blocks -> Some (from_id, to_id)'
after='  | Blocks -> Some (to_id, from_id)'

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
