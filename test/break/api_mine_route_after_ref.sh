#!/bin/sh
# Отрицательный контроль для claim'а api-mine-route.
#
# Что ломает: маршрут главного запроса. [Dream] разбирает маршруты по порядку,
# и параметризованный "/tasks/:ref" перехватывает "mine": запрос уходит в
# чтение задачи с референсом "mine" и кончается 404, а главный запрос не
# работает вовсе.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/server.ml
before='    Dream.get "/tasks/mine" Tasks.mine;
    Dream.get "/tasks/:ref" Tasks.get;'
after='    Dream.get "/tasks/:ref" Tasks.get;
    Dream.get "/tasks/mine" Tasks.mine;'

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
