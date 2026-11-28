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
import os
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


IGNORED = ("node_modules", "dist", ".git")


def _ignored(path):
    return any(part in IGNORED for part in path.parts)


def _walk_files(root):
    """Файлы дерева без игнорируемых каталогов.

    Обход идёт с отсечением: node_modules весит сотни мегабайт, и сплошной
    rglob по нему для каждого control'а превращал проверку в минуты."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED]
        for name in filenames:
            yield pathlib.Path(dirpath) / name


def changed_files(base, other):
    """Файлы, которые отличаются в двух деревьях, и файлы, добавленные в other."""
    changed = []
    for path in sorted(_walk_files(base)):
        rel = path.relative_to(base)
        mirror = other / rel
        if not mirror.is_file() or mirror.read_bytes() != path.read_bytes():
            changed.append(rel.as_posix())
    for path in sorted(_walk_files(other)):
        rel = path.relative_to(other)
        if path.is_file() and not (base / rel).is_file():
            changed.append(rel.as_posix())
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
            # node_modules и dist не нужны для проверки и весят сотни
            # мегабайт: без игнора копия каждого control'а съедала бы
            # диск и время.
            shutil.copytree(
                root / tree,
                case / tree,
                ignore=shutil.ignore_patterns("node_modules", "dist", ".git"),
            )

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
