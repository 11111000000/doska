#!/bin/sh
# Отрицательный контроль для claim'а overview-stuck-threshold.
#
# Что ломает: порог застоя перестаёт быть параметром запроса. Правка
# подменяет запрошенный порог фиксированным — клиент, спросивший «застой
# длиннее двух суток», получает сводку по другому правилу, а в ответе стоит
# чужое число.
#
# Ожидание: verifier (test/service_overview_test.exe) после этой правки падает.
set -eu

file=src/service/overview.ml
before="  let stuck_days = match stuck_days with Some n -> n | None -> default_stuck_days in"
after="  let stuck_days = match stuck_days with Some _ -> 36500 | None -> default_stuck_days in"

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
