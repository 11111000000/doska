#!/bin/sh
# Отрицательный контроль для claim'а service-layer-rules.
#
# Что ломает: правило или запись в базу переезжает из сервисного слоя в
# HTTP-обработчик. Правка пишет напрямую в репозиторий из адаптера — после
# неё REST снова ведёт себя иначе, чем MCP и CLI.
#
# Ожидание: verifier (test/check_service_layer.sh) после этой правки падает.
set -eu

file=src/api/tasks.ml
before='          | Some target ->
              answer'
after='          | Some target ->
              let _ = Db.Repo_task.set_status conn ~ref_ ~status:target ~version ~note:None in
              answer'

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
