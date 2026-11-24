#!/bin/sh
# Отрицательный контроль для claim'а api-ask-answer-contract.
#
# Что ломает: карточка задачи перестаёт отдавать адресата вопроса.
# Поле asked_to в ответе заменяется на null, хотя в базе адресат записан.
#
# Ожидание: verifier (test/task_question_test.exe) после этой правки падает:
# в карточке нет адресата, и клиент не видит, к кому вопрос.
set -eu

file=src/api/view.ml
before='      ("asked_to", opt t.Task.asked_to_name);'
after='      ("asked_to", `Null);'

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
