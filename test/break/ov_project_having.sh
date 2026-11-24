#!/bin/sh
# Отрицательный контроль для claim'а overview-project-load.
#
# Что ломает: в сводку попадают проекты без открытых задач. Правка снимает
# условие «есть открытые задачи» — пустой проект начинает занимать место в
# нагрузке, и список перестаёт отвечать на вопрос «где работа».
#
# Ожидание: verifier (test/service_overview_test.exe) после этой правки падает.
set -eu

file=src/db/repo_overview.ml
before='        HAVING count(t.id) > 0 \'
after='        HAVING count(t.id) >= 0 \'

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
