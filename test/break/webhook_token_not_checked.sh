#!/bin/sh
# Control для webhook-token-auth: проверка токена MM отключена.
set -eu
file=src/api/webhooks_mattermost.ml
before='value <> cfg.token'
after='value <> cfg.token && false'
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
