#!/bin/sh
# Отрицательный контроль для claim'а needs-input-migration.
#
# Что ломает: миграция 006 перестаёт быть идемпотентной — одна колонка
# добавляется без IF NOT EXISTS. Повторное применение файла на уже
# развёрнутой схеме падает с «column … already exists».
#
# Ожидание: verifier (sh test/check_task_question_migration.sh) после этой
# правки падает.

set -eu

file=migrations/006_task_question.sql
before='ALTER TABLE task ADD COLUMN IF NOT EXISTS question text;'
after='ALTER TABLE task ADD COLUMN question text;'

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
