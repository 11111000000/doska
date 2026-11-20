#!/bin/sh
# Отрицательный контроль для claim'а identity-resolve-alias-write.
#
# Что ломает: копирование алиаса в своё пространство имён. Правка пишет
# найденный в чужом пространстве алиас не туда, поэтому имя, найденное по
# чужому алиасу, в своём пространстве не появляется (§5.2, шаг 4).
#
# Ожидание: verifier (test/identity_db_test.exe) после этой правки падает.
set -eu

file=src/service/resolve.ml
before='        Db.Repo_actor_alias.add conn ~actor_id:actor.Actor.id ~namespace ~value ()'
after='        Db.Repo_actor_alias.add conn ~actor_id:actor.Actor.id ~namespace:"idn-чужое" ~value ()'

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
