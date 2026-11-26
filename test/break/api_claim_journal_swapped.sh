#!/bin/sh
# Отрицательный контроль для claim'а api-claim-journal.
#
# Что ломает: журнал помнит, что задача была заявлена — действие claimed, а не
# безымянная смена статуса. Правка пишет status_changed: по журналу нельзя
# отличить заявку от обычного перехода, и след претендента теряется.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='                          Db.Repo_activity.record conn ~action:Activity.Claimed'
after='                          Db.Repo_activity.record conn ~action:Activity.Status_changed'

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
