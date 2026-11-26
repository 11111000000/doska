#!/bin/sh
# Сверка перечислений TypeScript-ядра с доменом OCaml.
#
# Зеркало держится руками (tsc не видит OCaml), поэтому дрейф ловится
# механически: строковые значения to_string в src/domain обязаны совпасть
# с const-массивами frontend/packages/core/src/types.ts. Расхождение —
# exit 1 с именем перечисления и разницей.
#
# Работает из корня репозитория, база не нужна.
set -eu

python3 - <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(".")

pairs = [
    ("src/domain/status.ml", "to_string", "TASK_STATUSES"),
    ("src/domain/task.ml", "kind_to_string", "TASK_KINDS"),
    ("src/domain/task.ml", "priority_to_string", "TASK_PRIORITIES"),
    ("src/domain/link.ml", "to_string", "LINK_KINDS"),
    ("src/domain/actor.ml", "kind_to_string", "ACTOR_KINDS"),
    ("src/domain/activity.ml", "action_to_string", "ACTIVITY_ACTIONS"),
    ("src/domain/actor.ml", "autonomy_to_string", "PROJECT_AUTONOMY"),
]

def ocaml_values(path, fn):
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"let {fn}\b", line):
            start = i + 1
            break
    if start is None:
        sys.exit(f"нет функции {fn} в {path}")
    values = []
    for line in lines[start:]:
        if re.match(r"let ", line):
            break
        values += re.findall(r'"([a-z_][a-z0-9_]*)"', line)
    return values

def ts_values(name):
    text = (root / "frontend/packages/core/src/types.ts").read_text(encoding="utf-8")
    match = re.search(rf"export const {name} = \[(.*?)\] as const", text, re.S)
    if match is None:
        sys.exit(f"нет массива {name} в frontend/packages/core/src/types.ts")
    return re.findall(r'"([a-z_][a-z0-9_]*)"', match.group(1))

problems = []
for path, fn, name in pairs:
    left = ocaml_values(path, fn)
    right = ts_values(name)
    if left != right:
        missing = sorted(set(left) - set(right))
        extra = sorted(set(right) - set(left))
        problems.append(
            f"{name} против {path}:{fn}: "
            f"нет в TS: {missing}; лишние в TS: {extra}"
        )

if problems:
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1)
print(f"types: {len(pairs)} перечислений совпадают с доменом OCaml")
PY
