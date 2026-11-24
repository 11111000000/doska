#!/bin/sh
# Отрицательный контроль для claim'а needs-input-notification.
#
# Что ломает: при постановке вопроса в outbox кладётся уведомление адресату.
# Правка меняет канал доставки, и уведомление уходит не адресату, а в
# общий канал: человек, от которого ждут ответа, о нём не узнаёт, а шум
# получает весь проект.
#
# Ожидание: verifier (test/task_question_test.exe) после этой правки падает.
set -eu

file=src/db/repo_notification.ml
before="           VALUES (%s, %s, 'mattermost_dm', %s, %s::jsonb)\""
after="           VALUES (%s, %s, 'mattermost_channel', %s, %s::jsonb)\""

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
