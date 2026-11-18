#!/bin/sh
# Отрицательный контроль для claim'а db-project-lookup.
#
# Что ломает: поиск проекта по ключу. Правка ищет по названию вместо ключа,
# поэтому ссылка на проект по ключу (например, «doska») перестаёт работать
# (§3.2).
#
# Ожидание: verifier (test/repo_test.exe) после этой правки падает.
set -eu

file=src/db/repo_project.ml
before='    (Printf.sprintf "%s WHERE p.key = %s" select (Conn.quote key))'
after='    (Printf.sprintf "%s WHERE p.name = %s" select (Conn.quote key))'

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
