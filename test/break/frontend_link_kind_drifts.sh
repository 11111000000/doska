#!/bin/sh
# Отрицательный контроль для claim'а frontend-types-match-domain.
#
# Что ломает: вид связи в зеркале TS расходится с доменом OCaml
# («split_from» превращается в «splits_from»). Реальный дрейф этого
# рода уже находился при первой сверке.
#
# Ожидание: verifier (sh test/check_frontend_types.sh) падает.
set -eu

file=frontend/packages/core/src/types.ts
before='"split_from",'
after='"splits_from",'

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
