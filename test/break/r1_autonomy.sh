#!/bin/sh
# Отрицательный контроль для claim'а r1-agent-acceptance.
#
# Что ломает: правило R1 — агент закрывает задачу сам в любом проекте.
# Правка делает условие «проект доверенный» всегда истинным, поэтому
# агент в проекте с autonomy = human_gate получает право закрыть задачу.
#
# Ожидание: verifier (тесты домена) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='ctx.project_autonomy = Actor.Auto then Ok ()'
after='ctx.project_autonomy = Actor.Auto || true then Ok ()'

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
