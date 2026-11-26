#!/bin/sh
# Control для claim'а frontend-web-app: index.html теряет входную точку —
# приложение открывается пустой страницей.
set -eu
file=frontend/apps/web/index.html
before='<script type="module" src="./app.js"></script>'
after='<!-- входная точка удалена -->'
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
