#!/bin/sh
# Отрицательный контроль для claim'а api-mine-pagination.
#
# Что ломает: курсорная пагинация главного запроса. Сравнение со строгого
# «строго следующая» становится на «не меньше», и курсорная строка попадает
# в следующую страницу снова: клиент обходит список и одну и ту же задачу
# получает дважды.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='                  "(%s > (SELECT %s FROM task c WHERE c.id = %s))"'
after='                  "(%s >= (SELECT %s FROM task c WHERE c.id = %s))"'

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
