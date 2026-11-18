#!/bin/sh
# Отрицательный контроль для claim'а test-harness-needs-db.
#
# Что ломает: честность обвязки тестов. Правка перестаёт читать
# DOSKA_DATABASE_URL и молча берёт настоящую базу, поэтому тест, которому нужна
# база, «проходит мимо» вместо того, чтобы упасть без базы (решение этапа 1:
# тесты живут на настоящей базе).
#
# Подставляется та же база, что и в окружении, где control работает: жёстко
# зашитый сокет означал бы, что в CI (postgres только по TCP) правка ничего не
# ломает и контроль не достигает claim'а.
#
# Ожидание: verifier (test/check_tests_need_db.sh) после этой правки падает.
set -eu

file=test/support.ml
before='let database_url () =
  match Sys.getenv_opt "DOSKA_DATABASE_URL" with
  | Some u when String.trim u <> "" -> u
  | _ -> "postgresql:///doska"'

db=${DOSKA_DATABASE_URL:-postgresql:///doska}

python3 - "$file" "$before" "$db" <<'PY'
import pathlib, sys

path, before, db = sys.argv[1], sys.argv[2], sys.argv[3]
escaped = db.replace("\\", "\\\\").replace('"', '\\"')
after = 'let database_url () = "%s"' % escaped
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
count = text.count(before)
if count != 1:
    sys.exit(f"правка не применилась: {before!r} встречается {count} раз в {path}, нужен 1")
p.write_text(text.replace(before, after), encoding="utf-8")
PY
