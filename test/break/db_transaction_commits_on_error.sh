#!/bin/sh
# Отрицательный контроль для claim'а db-transaction-atomicity.
#
# Что ломает: откат транзакции. Правка вместо ROLLBACK делает COMMIT, поэтому
# изменения, сделанные до сбоя, остаются в базе: половина обязательства
# сохраняется, хотя операция провалилась.
#
# Ожидание: verifier (test/repo_test.exe) после этой правки падает.
set -eu

file=src/db/conn.ml
before='          let* _ = exec_sql conn "ROLLBACK" in'
after='          let* _ = exec_sql conn "COMMIT" in'

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
