#!/bin/sh
# Отрицательный контроль для claim'а migration-immutable.
#
# Что ломает: сверку контрольной суммы применённой миграции. Правка
# убирает сравнение суммы файла с записанной в базе, поэтому изменённый
# после применения файл мигратор принимает молча.
#
# Правка точечная: сравнение заменяется на безусловное «совпало», а
# проверка «файл существует» остаётся на месте. Если бы сломалась вся
# компиляция модуля, контроль ничего бы не доказывал — падение verifier'а
# тогда вызвано не свойством, а синтаксисом.
#
# Ожидание: verifier (test/check_migration.sh immutable) после этой правки
# падает с сообщением о принятом изменённом файле.
set -eu

file=src/db/migrate.ml
before='if actual = recorded then check rest'
after='if true then check rest'

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
