#!/bin/sh
# Отрицательный контроль для claim'а db-evidence-ownership.
#
# Что ломает: принадлежность доказательства своей задаче. Правка убирает
# условие «доказательство этой задачи», поэтому чужая ссылка на коммит
# попадает в карточку другой задачи (§3.4).
#
# Ожидание: verifier (test/repo_test.exe) после этой правки падает.
set -eu

file=src/db/repo_evidence.ml
before='           "SELECT row_to_json(e)::text FROM evidence e WHERE e.task_id = %s \'
after='           "SELECT row_to_json(e)::text FROM evidence e WHERE %s::text IS NOT NULL \'

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
