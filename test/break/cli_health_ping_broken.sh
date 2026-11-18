#!/bin/sh
# Отрицательный контроль для claim'а cli-health-and-version.
#
# Что ломает: проверку живости базы. Правка портит запрос, на котором
# построена проверка, поэтому health перестаёт видеть живую базу и сообщает
# об ошибке там, где всё работает (§6.3, §9.1).
#
# Ожидание: verifier (test/check_cli.sh) после этой правки падает.
set -eu

file=src/db/conn.ml
before="  query_strings conn \"SELECT 'ok'\""
after="  query_strings conn \"SELECT 'ok' FROM doska_absent_ping_table\""

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
