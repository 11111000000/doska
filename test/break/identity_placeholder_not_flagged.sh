#!/bin/sh
# Отрицательный контроль для claim'а identity-placeholder-write.
#
# Что ломает: признак заглушки. Правка создаёт заглушку с unresolved = false,
# поэтому по записи нельзя отличить неразрешённое имя от настоящего
# актёра (§3.1).
#
# Ожидание: verifier (test/identity_db_test.exe) после этой правки падает.
set -eu

file=src/db/repo_actor.ml
before="       VALUES ('placeholder'::actor_kind, %s, %s, true) RETURNING id::text\""
after="       VALUES ('placeholder'::actor_kind, %s, %s, false) RETURNING id::text\""

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
