#!/bin/sh
# Отрицательный контроль для claim'а needs-input-addressee-resolved.
#
# Что ломает: первый шаг цепочки вывода адресата — заявитель задачи.
# Вместо заявителя кандидатом становится «никто»: цепочка идёт дальше
# (руководитель исполнителя, руководитель заявителя, администратор) или
# упирается в отсутствие адресата.
#
# Ожидание: verifier (test/task_question_test.exe) после этой правки падает:
# вопрос, адресованный заявителю, уходит другому человеку.
set -eu

file=src/service/task.ml
before='          | Some id -> human_addressee conn id'
after='          | Some _id -> Lwt_result.lift (Ok None)'

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
