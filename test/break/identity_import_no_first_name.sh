#!/bin/sh
# Отрицательный контроль для claim'а identity-import-aliases.
#
# Что ломает: алиас по имени без фамилии. Правка берёт вместо имени ник,
# поэтому алиаса «Пётр» не появляется, и имя, которым человека зовут в чате,
# больше не разрешается в «Пётр Косов» (§5.3).
#
# Ожидание: verifier (test/identity_db_test.exe) после этой правки падает.
set -eu

file=src/service/import_actors.ml
before='  let display = display_name_of user in
  let first = String.trim user.Mattermost.first_name in'
after='  let display = display_name_of user in
  let first = String.trim user.Mattermost.nickname in'

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
