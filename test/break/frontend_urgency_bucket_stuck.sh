#!/bin/sh
# Отрицательный контроль для claim'а frontend-core-contracts.
#
# Что ломает: bucketOf перестаёт различать просроченные задачи — все
# задачи со сроком падают в корзину «later», срочность теряется.
#
# Ожидание: verifier (test/check_frontend_core.sh) падает на node --test.
set -eu

file=frontend/packages/core/src/logic/urgency.ts
before='  if (due < now.getTime()) return "overdue";'
after='  if (due < now.getTime()) return "later";'

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
