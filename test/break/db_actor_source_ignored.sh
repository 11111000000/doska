#!/bin/sh
# Отрицательный контроль для claim'а db-actor-source-lookup.
#
# Что ломает: составной ключ источника. Правка ищет актёра по любой части
# ключа, а не по паре (source, source_ref), поэтому актёр одного источника
# находится по ключу другого (§10.2).
#
# Ожидание: verifier (test/identity_db_test.exe) после этой правки падает.
set -eu

file=src/db/repo_actor.ml
before='    (Printf.sprintf "%s WHERE a.source = %s AND a.source_ref = %s" select'
after='    (Printf.sprintf "%s WHERE a.source = %s OR a.source_ref = %s" select'

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
