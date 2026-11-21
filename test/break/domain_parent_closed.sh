#!/bin/sh
# Отрицательный контроль для claim'а domain-parent-closed.
#
# Что ломает: родителя не закрывают, пока открыты дети. Правка убирает это
# условие, и сводка обманывает читателя: закрытый родитель с открытыми
# детьми выглядит как сделанная работа, которой никто не делал.
#
# Ожидание: verifier (test/domain_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='    if ctx.open_children = 0 then Ok ()'
after='    if ctx.open_children >= 0 then Ok ()'

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
