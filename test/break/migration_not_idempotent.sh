#!/bin/sh
# Отрицательный контроль для claim'а migration-idempotent.
#
# Что ломает: идемпотентность файла миграции. Правка убирает IF NOT EXISTS
# у одной таблицы, поэтому повторное применение SQL падает с «relation
# already exists» вместо того, чтобы завершиться успешно.
#
# Ожидание: verifier (test/check_migration.sh idempotent) после этой правки
# падает.
set -eu

file=migrations/001_init.sql
before='CREATE TABLE IF NOT EXISTS actor ('
after='CREATE TABLE actor ('

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
