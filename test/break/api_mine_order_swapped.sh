#!/bin/sh
# Отрицательный контроль для claim'а api-mine-order.
#
# Что ломает: порядок главного запроса. Корзины срочности меняются местами:
# задача без срока становится самой срочной, а просроченная уезжает в конец.
# Человек открывает «мои задачи» и видит пустое первым — а просроченное он
# не видит вовсе.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='THEN 3 WHEN %s.due_at < now() THEN 0'
after='THEN 0 WHEN %s.due_at < now() THEN 3'

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
