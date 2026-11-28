#!/bin/sh
# Отрицательный контроль для claim'а projects-endpoint: проверка ключа
# проекта отключена — произвольный ключ («Плохой Ключ») принимается.
set -eu
file=src/api/projects.ml
before='  if !ok then Ok () else Error ("неверный key проекта: " ^ key)'
after='  if !ok then Ok () else Ok ()'
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
