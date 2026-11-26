#!/bin/sh
# Control для claim'а paseo-plugin-installed: имя RPC с заглавной буквой —
# defineRpc отвергает его при загрузке, плагин падает (реальный отказ
# первой установки doska).
set -eu
file=frontend/plugins/paseo/shared/doska-rpc.ts
before='"doska.my_tasks"'
after='"doska.myTasks"'
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
