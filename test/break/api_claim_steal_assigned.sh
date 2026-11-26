#!/bin/sh
# Отрицательный контроль для claim'а api-claim-assignee-scope.
#
# Что ломает: заявку может подать только претендент — агент, которому задача
# ещё не назначена, либо её исполнитель. Правка убирает последнюю проверку:
# любой агент забирает задачу, назначенную другому, и работа двух претендентов
# расходится на полях.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='      else if ctx.assignee_id = Some ctx.actor.id then Ok ()
      else Error "Задача назначена другому исполнителю"'
after='      else Ok ()'

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
