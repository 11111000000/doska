#!/bin/sh
# Отрицательный контроль для claim'а identity-import-kind.
#
# Что ломает: различатель «человек или агент». Правка оставляет только
# должность, поэтому служебные учётные записи без должности (bots в Mattermost
# живут в домене @localhost) попадают в трекер как люди (§5.3).
#
# Ожидание: verifier (test/identity_db_test.exe) после этой правки падает.
set -eu

file=src/service/import_actors.ml
before='  else if String.ends_with ~suffix:"@localhost" email then Actor.Agent'
after='  else if String.ends_with ~suffix:"@localhost.invalid" email then Actor.Agent'

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
