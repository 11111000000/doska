#!/bin/sh
# Отрицательный контроль для claim'а task-upsert-from-source.
#
# Что ломает: upsert перестаёт обновлять существующую задачу — любое
# изменение из источника молча пропускается, версия не растёт, журнал
# молчит. Формально «не дублирует», но и не обновляет: половина контракта
# §10.2 потеряна.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/service/task.ml
before='          if changed_fields fields = [] then'
after='          if true then'

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
