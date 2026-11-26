#!/bin/sh
# Отрицательный контроль для claim'а api-actors-resolve.
#
# Что ломает: маршрут разрешения имён. Правка убирает его из сервера, и
# вопрос «кто это» больше не имеет ответа: клиент получает 404 вместо
# актёра или заглушки (§6.1).
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/server.ml
before='    Dream.post "/actors/resolve" Actors.resolve;
'
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
