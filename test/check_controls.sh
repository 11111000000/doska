#!/bin/sh
# Отрицательные control'ы — часть доказательства: claim без control'а не
# claim (math-coding). Здесь проверяется, что каждый control
#   * меняет свой предмет ровно в одном месте,
#   * применим к текущим исходникам (устаревший control ничего не доказывает),
#   * объявлен control'ом ровно одного claim'а в spec.json.
#
# Сама проверка работает на копии дерева: control'ы правят файлы, и после
# проверки рабочее дерево остаётся нетронутым.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

python3 - <<'PY'
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path.cwd()
break_dir = root / "test" / "break"
trees = ("src", "test", "migrations", "frontend")

spec = json.loads((root / "spec.json").read_text(encoding="utf-8"))
declared = {}
for claim in spec["claims"]:
    control = claim.get("control")
    if not control:
        continue
    declared.setdefault(control.split()[-1], []).append(claim["id"])

scripts = sorted(break_dir.glob("*.sh"))
problems = []

for script in scripts:
    rel = script.relative_to(root).as_posix()
    owners = declared.get(rel, [])
    if len(owners) != 1:
        problems.append(f"{rel}: control'ом объявлен {len(owners)} claim'ов, нужен ровно один")

for path in sorted(declared):
    if not (root / path).is_file():
        problems.append(f"{path}: control'а нет на диске")

if problems:
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1)


def changed_files(base, other):
    """Файлы, которые отличаются в двух деревьях, и файлы, добавленные в other."""
    changed = []
    for path in sorted(base.rglob("*")):
        if not path.is_file():
            continue
        mirror = other / path.relative_to(base)
        if not mirror.is_file() or mirror.read_bytes() != path.read_bytes():
            changed.append(path.relative_to(base).as_posix())
    for path in sorted(other.rglob("*")):
        if path.is_file() and not (base / path.relative_to(other)).is_file():
            changed.append(path.relative_to(other).as_posix())
    return changed


with tempfile.TemporaryDirectory() as tmp:
    case = pathlib.Path(tmp) / "case"
    for script in scripts:
        rel = script.relative_to(root).as_posix()

        syntax = subprocess.run(["sh", "-n", rel], capture_output=True, text=True)
        if syntax.returncode != 0:
            print(f"{rel}: невалидный shell: {syntax.stderr.strip()}", file=sys.stderr)
            sys.exit(1)

        if case.exists():
            shutil.rmtree(case)
        case.mkdir()
        for tree in trees:
            shutil.copytree(root / tree, case / tree)

        applied = subprocess.run(["sh", rel], cwd=case, capture_output=True, text=True)
        if applied.returncode != 0:
            print(f"{rel}: правка не применилась: {applied.stderr.strip()}", file=sys.stderr)
            sys.exit(1)

        changed = []
        for tree in trees:
            changed.extend(changed_files(root / tree, case / tree))
        if len(changed) != 1:
            print(
                f"{rel}: правка меняет {len(changed)} места ({', '.join(changed)}), нужно ровно одно",
                file=sys.stderr,
            )
            sys.exit(1)

print(f"controls: {len(scripts)} control'ов меняют ровно один файл и применимы к исходникам")
PY
