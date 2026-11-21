#!/bin/sh
# Отрицательный контроль для claim'а api-link-unlink-scope.
#
# Что ломает: связь снимается из своей задачи; снять чужую связь из чужой
# задачи — не то действие, о котором просили. Правка снимает любую связь из
# любой задачи, и задача теряет отношения, которые ей не принадлежат.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='          let touches =
            link.Db.Repo_link.from_id = task.Task.id
            || link.Db.Repo_link.to_id = task.Task.id
          in'
after='          let touches = true in'

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
