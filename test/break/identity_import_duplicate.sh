#!/bin/sh
# Отрицательный контроль для claim'а identity-import-idempotent.
#
# Что ломает: ключ источника при записи актёра. Правка записывает в
# source_ref другое значение, поэтому повторный импорт того же пользователя
# не находит свою строку по ключу и падает вместо того, чтобы обновить её
# (§10.2).
#
# Ожидание: verifier (test/identity_db_test.exe) после этой правки падает.
set -eu

file=src/db/repo_actor.ml
before='              (Conn.quote source)
              (Conn.quote source_ref)'
after='              (Conn.quote source)
              (Conn.quote (source_ref ^ "-другой"))'

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
