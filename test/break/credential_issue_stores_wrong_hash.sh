#!/bin/sh
# Отрицательный контроль для claim'а credential-issue-roundtrip.
#
# Что ломает: в учётку записывается хэш не предъявленного токена, а его
# названия — выданный токен перестаёт опознаваться проверкой.
#
# Ожидание: verifier (test/service_credential_test.exe) падает.
set -eu

file=src/service/credential.ml
before='~token_hash:(hash_hex token)'
after='~token_hash:(hash_hex title)'

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
