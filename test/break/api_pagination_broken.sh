#!/bin/sh
# Отрицательный контроль для claim'а api-list-pagination.
#
# Что ломает: курсорная пагинация. Страница берётся на одну строку больше
# лимита — так видно, есть ли следующая страница. Правка убирает этот запас,
# и курсор следующей страницы пропадает: клиент обходит только первую
# страницу и не знает, что список не кончился.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='      task_select where (f.limit + 1)'
after='      task_select where f.limit'

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
