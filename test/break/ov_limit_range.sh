#!/bin/sh
# Отрицательный контроль для claim'а overview-parameter-range.
#
# Что ломает: граница допустимого предела разъезжается. Правка поднимает
# максимум — клиент, запросивший limit=1000, больше не получает отказ, и
# сервис соглашается считать по значению, которого не обязан принимать.
#
# Ожидание: verifier (test/service_overview_test.exe) после этой правки падает.
set -eu

file=src/service/overview.ml
before="let max_limit = 200"
after="let max_limit = 100000"

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
