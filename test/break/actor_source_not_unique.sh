#!/bin/sh
# Отрицательный контроль для claim'а migration-actor-source.
#
# Что ломает: уникальность ключа источника. Правка убирает UNIQUE у индекса
# на паре (source, source_ref), поэтому один и тот же внешний объект
# заводится в базе дважды — импорт перестаёт быть идемпотентным (§10.2).
#
# Ожидание: verifier (test/check_actor_source.sh) после этой правки падает.
set -eu

file=migrations/003_actor_source.sql
before='CREATE UNIQUE INDEX IF NOT EXISTS actor_source_ref_uniq'
after='CREATE INDEX IF NOT EXISTS actor_source_ref_uniq'

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
