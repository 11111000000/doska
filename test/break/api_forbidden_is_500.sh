#!/bin/sh
# Отрицательный контроль для claim'а api-transition-r1.
#
# Что ломает: запрет правила домена обязан превращаться в 403 с понятным
# телом. Правка отвечает Internal, поэтому клиент получает 500 («сломалось
# наше») вместо «правило запрещает» — ровно то, чего API обещать не должен.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/tasks.ml
before='(Errors.make Errors.Forbidden message
                  ~details:'
after='(Errors.make Errors.Internal message
                  ~details:'

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
