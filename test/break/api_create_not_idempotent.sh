#!/bin/sh
# Отрицательный контроль для claim'а api-idempotent-create.
#
# Что ломает: дедупликация по паре (source, source_ref). Правка заставляет
# репозиторий не смотреть в базу перед вставкой, поэтому повторное создание
# либо плодит дубль, либо упирается в уникальный индекс и возвращает ошибку
# вместо той же задачи.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/db/repo_task.ml
before='    | Some source, Some source_ref -> by_source_ref conn ~source ~source_ref'
after='    | Some source, Some source_ref -> Lwt_result.map (fun _ -> None) (by_source_ref conn ~source ~source_ref)'

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
