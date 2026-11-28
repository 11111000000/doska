#!/bin/sh
# Отрицательный контроль для claim'а credential-foreign-revoke-needs-admin.
#
# Что ломает: проверка владения переворачивается. Сравнение владельца
# меняется с «не совпадает» на «совпадает»: чужую учётку отзывает кто угодно
# без прав администратора, а свою — наоборот, уже не отозвать без них.
#
# Правка меняет поведение, а не сборку: cred, by_actor_id и admin остаются
# используемыми, поэтому предупреждение о неиспользуемой переменной
# (-warn-error +a) не превращает контроль в пустое доказательство.
#
# Ожидание: verifier (test/service_credential_test.exe) падает.
set -eu

file=src/service/credential.ml
before='if cred.actor_id <> by_actor_id && not admin then'
after='if cred.actor_id = by_actor_id && not admin then'

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
