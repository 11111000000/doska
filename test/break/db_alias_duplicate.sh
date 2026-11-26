#!/bin/sh
# Отрицательный контроль для claim'а db-alias-repository.
#
# Что ломает: идемпотентность записи алиаса. Правка убирает ON CONFLICT,
# поэтому повторная запись того же имени в том же пространстве падает с
# нарушением уникальности вместо того, чтобы вернуть существующий алиас
# (§5.2).
#
# Ожидание: verifier (test/identity_db_test.exe) после этой правки падает.
set -eu

file=src/db/repo_actor_alias.ml
before='           ON CONFLICT (namespace, alias) DO NOTHING RETURNING id::text"'
after='           RETURNING id::text"'

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
