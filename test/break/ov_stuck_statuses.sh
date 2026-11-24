#!/bin/sh
# Отрицательный контроль для claim'а overview-stuck-rule.
#
# Что ломает: застой перестаёт отличаться от ожидания ответа. Правка добавляет
# needs_input в список начатых статусов — задача, которая честно ждёт человека,
# попадает в «застрявшие» (R2, ADR §4.2).
#
# Ожидание: verifier (test/service_overview_test.exe) после этой правки падает.
set -eu

file=src/db/repo_overview.ml
before="let stuck_statuses = \"'in_progress','blocked','in_review'\""
after="let stuck_statuses = \"'in_progress','blocked','in_review','needs_input'\""

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
