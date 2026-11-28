#!/bin/sh
# Отрицательный контроль для claim'а frontend-board-d3: D3 не вендорится —
# обзор без библиотеки не рисуется (единственная runtime-зависимость веба).
set -eu
file=frontend/apps/web/build.sh
before='cp ../../node_modules/d3/dist/d3.min.js dist/vendor/d3.min.js'
after=':'
python3 - "$file" "$before" "$after" <<'PY'
import pathlib, sys
path, before, after = sys.argv[1:4]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
count = text.count(before)
if count != 1:
    sys.exit(f"правка не применилась: {before!r} встречается {count} раз, нужен 1")
p.write_text(text.replace(before, after), encoding="utf-8")
PY
