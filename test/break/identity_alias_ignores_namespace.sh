#!/bin/sh
# Отрицательный контроль для claim'а identity-alias-namespace.
#
# Что ломает: пространства имён алиасов. Правка ищет алиас в любом
# пространстве, поэтому алиас из чужого пространства начинает работать как
# свой: пространство имён перестаёт разделять «петров» из Mattermost и
# «p.tr» из git (§5.2).
#
# Ожидание: verifier (test/identity_test.exe) после этой правки падает.
set -eu

file=src/identity/resolve.ml
before='            (fun (al : alias) -> al.namespace = namespace && normalize al.value = n)'
after='            (fun (al : alias) -> (ignore namespace; normalize al.value = n))'

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
