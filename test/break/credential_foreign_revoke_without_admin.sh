#!/bin/sh
# Отрицательный контроль для claim'а credential-foreign-revoke-needs-admin.
#
# Что ломает: проверка владельца учётки отключена — любой актор отзывает
# любую учётку без прав администратора.
#
# Ожидание: verifier (test/service_credential_test.exe) падает.
set -eu

file=src/service/credential.ml
before='if cred.actor_id <> by_actor_id && not admin then'
after='if false then'

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
