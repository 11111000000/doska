#!/bin/sh
# Отрицательный контроль для claim'а api-release-owner.
#
# Что ломает: отпустить задачу может её исполнитель-агент или любой человек.
# Правка снимает ограничение: посторонний агент отпускает чужую работу, и
# исполнитель теряет задачу, которую вёл.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='      else if ctx.assignee_id = Some ctx.actor.id then Ok ()
      else Error "Отпустить задачу может её исполнитель или человек"'
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
