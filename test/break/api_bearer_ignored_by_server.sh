#!/bin/sh
# Отрицательный контроль для claim'а api-bearer-auth.
#
# Что ломает: сервер перестаёт читать заголовок Authorization — bearer
# не опознаётся, приоритет над запасным заголовком теряется.
#
# Ожидание: verifier (test/api_test.exe) падает.
set -eu

file=src/api/auth.ml
before='match Dream.headers req authorization_header with'
after='match Dream.headers req "x-doska-absent" with'

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
