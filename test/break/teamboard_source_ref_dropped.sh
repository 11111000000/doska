#!/bin/sh
# Отрицательный контроль для claim'а teamboard-import-idempotent:
# ключ источника теряется, и повторный импорт плодит дубли задач (§10.2).
set -eu

file=src/service/import_teamboard.ml
before='                  source_ref = Some card_key;'
after='                  source_ref = None;'

python3 - "$file" "$before" "$after" <<'PY'
import pathlib, sys

path, before, after = sys.argv[1:4]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
count = text.count(before)
if count != 1:
    sys.exit(f"правка не применилась: {before!r} встречается {count} раз, нужен 1")
p.write_text(text.replace(before, after), encoding="utf-8")
PY
