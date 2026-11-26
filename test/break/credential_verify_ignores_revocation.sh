#!/bin/sh
# Отрицательный контроль для claim'а credential-revoke-gates-access.
#
# Что ломает: проверка перестаёт смотреть на revoked_at — отозванная
# учётка продолжает проходить проверку, и «отзыв» становится записью
# для галочки.
#
# Ожидание: verifier (test/service_credential_test.exe) падает.
set -eu

file=src/db/repo_credential.ml
before='AND c.revoked_at IS NULL'
after=''

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
