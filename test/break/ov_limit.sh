#!/bin/sh
# Отрицательный контроль для claim'а overview-limit.
#
# Что ломает: предел длины списков перестаёт быть параметром запроса. Правка
# подменяет запрошенный предел максимальным — сервис отдаёт весь список и
# сообщает в ответе другое число, чем просил клиент.
#
# Ожидание: verifier (test/service_overview_test.exe) после этой правки падает.
set -eu

file=src/service/overview.ml
before="  let limit = match limit with Some n -> n | None -> default_limit in"
after="  let limit = match limit with Some _ -> max_limit | None -> default_limit in"

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
