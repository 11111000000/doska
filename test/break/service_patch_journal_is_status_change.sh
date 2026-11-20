#!/bin/sh
# Отрицательный контроль для claim'а service-patch-journal.
#
# Что ломает: правка задачи пишется в журнал как смена статуса. След перестаёт
# отвечать на вопрос «что изменилось»: и правка, и переход выглядят
# одинаково, а сводка изменённых полей пропадает.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='~action:Activity.Updated'
after='~action:Activity.Status_changed'

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
