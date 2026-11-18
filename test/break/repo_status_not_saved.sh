#!/bin/sh
# Отрицательный контроль для claim'а repo-status-persistence.
#
# Что ломает: оптимистичная блокировка по version. Правка перестаёт
# увеличивать версию при смене статуса, поэтому две правки с одной и той же
# версией проходят: вторая молча затирает первую — «ни одно изменение не
# теряется» перестаёт быть правдой.
#
# Ожидание: verifier (test/repo_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='"UPDATE task SET status = %s::task_status, version = version + 1, \'
after='"UPDATE task SET status = %s::task_status, version = version, \'

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
