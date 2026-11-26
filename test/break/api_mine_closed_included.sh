#!/bin/sh
# Отрицательный контроль для claim'а api-mine-open-only.
#
# Что ломает: главный запрос отдаёт только открытые задачи. Правка убирает
# отбор по статусу, и закрытая работа остаётся в «моих задачах»: агент берёт
# то, что уже сдано, и отчёт о загрузке врёт.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before="            \"t.status NOT IN ('done','cancelled')\";"
after="            \"t.status IS NOT NULL\";"

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
