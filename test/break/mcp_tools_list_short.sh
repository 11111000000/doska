#!/bin/sh
# Control для mcp-tools-contract: tools/list теряет один инструмент.
set -eu
file=src/mcp/server.ml
before='("tools", tool_descriptors) ])'
after='("tools", List.tl tool_descriptors) ])'
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
