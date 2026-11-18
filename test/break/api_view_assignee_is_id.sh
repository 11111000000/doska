#!/bin/sh
# Отрицательный контроль для claim'а api-view-links.
#
# Что ломает: читаемость карточки задачи. Правка отдаёт в поле «assignee»
# идентификатор вместо имени, поэтому человек видит uuid там, где ждал
# имя исполнителя (§3.1, П1).
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/view.ml
before='      ("assignee", opt t.Task.assignee_name);'
after='      ("assignee", opt t.Task.assignee_id);'

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
