#!/bin/sh
# Отрицательный контроль для claim'а api-claim-source-status.
#
# Что ломает: заявка подаётся только на задачу в статусе todo — из backlog
# претендентов нет, задача ещё не поставлена в работу. Правка расширяет
# перечень исходных статусов, и заявка перестаёт быть конфликтом состояния.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='  if status = Todo then Ok ()'
after='  if status = Backlog || status = Todo then Ok ()'

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
