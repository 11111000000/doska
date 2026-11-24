#!/bin/sh
# Отрицательный контроль для claim'а needs-input-history.
#
# Что ломает: новый вопрос обнуляет прежний ответ. Правка оставляет старый
# ответ на месте, и карточка показывает ответ на прошлый вопрос как будто он
# отвечает на текущий: читатель видит зелёную задачу с ответом, которого
# никто не давал.
#
# Ожидание: verifier (test/task_question_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='        "UPDATE task SET question = %s, asked_to_id = %s, answer = NULL, \'
after='        "UPDATE task SET question = %s, asked_to_id = %s, answer = answer, \'

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
