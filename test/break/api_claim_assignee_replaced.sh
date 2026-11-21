#!/bin/sh
# Отрицательный контроль для claim'а api-claim-assignee.
#
# Что ломает: заявка назначает задачу себе только если она была свободна.
# Правка назначает заявителя всегда — и заявка отменяет назначение,
# принятое ранее человеком: чужой исполнитель молча теряет задачу.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='              let assignee =
                match task.Task.assignee_id with
                | None -> Some (Some actor.Actor.id)
                | Some _ -> None
              in'
after='              let assignee = Some (Some actor.Actor.id) in'

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
