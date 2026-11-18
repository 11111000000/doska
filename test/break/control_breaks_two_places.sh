#!/bin/sh
# Отрицательный контроль для claim'а controls-prove-verifiers.
#
# Что ломает: правило «control меняет предмет ровно в одном месте». Правка
# дописывает в существующий control вторую правку — после этого control меняет
# уже два места, и доказательство перестаёт быть точечным: падение verifier'а
# может быть вызвано не тем свойством, которое проверялось.
#
# Ожидание: verifier (test/check_controls.sh) после этой правки падает.
set -eu

file=test/break/r1_autonomy.sh

python3 - "$file" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "Второе место" in text:
    sys.exit("правка уже применена")
addition = """
# Второе место: та же правка задевает ещё и имя статуса.
python3 - src/domain/status.ml <<'PY2'
import pathlib
import sys

p = pathlib.Path("src/domain/status.ml")
text = p.read_text(encoding="utf-8")
before = '  | Backlog -> "backlog"'
after = '  | Backlog -> "backlog!"'
count = text.count(before)
if count != 1:
    sys.exit(f"правка не применилась: {before!r} встречается {count} раз, нужен 1")
p.write_text(text.replace(before, after), encoding="utf-8")
PY2
"""
path.write_text(text.rstrip("\n") + "\n" + addition, encoding="utf-8")
PY
