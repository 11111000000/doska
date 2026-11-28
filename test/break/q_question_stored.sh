#!/bin/sh
# Отрицательный контроль для claim'а needs-input-question-stored.
#
# Что ломает: текст вопроса сохраняется в задаче. Правка склеивает
# question с NULL — в SQL это всегда NULL, — и задача уходит ждать ответа без
# вопроса: адресат видит в карточке, что от него ждут, но не видит чего
# именно — вопрос жив только в переписке, а не в трекере.
#
# Правка меняет поведение, а не сборку: число плейсхолдеров в форматной
# строке остаётся прежним, поэтому тип формата сходится и контроль не
# превращается в пустое доказательство.
#
# Ожидание: verifier (test/task_question_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='        "UPDATE task SET question = %s, asked_to_id = %s, answer = NULL, \'
after='        "UPDATE task SET question = NULL || %s, asked_to_id = %s, answer = NULL, \'

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
