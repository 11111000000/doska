#!/bin/sh
# Control для task-from-chat-idempotent: ключ источника перестаёт быть
# постоянным — повтор той же команды создаёт вторую задачу (falsifier).
#
# Ключ должен меняться от вызова к вызову, иначе повтор всё равно найдёт
# ту же задачу. При этом trigger_id обязан остаться используемым: если
# убрать последнее упоминание, компилятор падает с warning 27 (unused
# variable), и control «доказывает» не идемпотентность, а поломку
# сборки — такое падение доказательством не является.
set -eu
file=src/api/webhooks_mattermost.ml
before='source_ref = Some ("cmd:" ^ trigger_id);'
after='source_ref = Some ("cmd:" ^ trigger_id ^ string_of_int (Random.int 1_000_000_000));'
python3 - "$file" "$before" "$after" <<'PY'
import pathlib, sys
path, before, after = sys.argv[1:4]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
count = text.count(before)
if count != 1:
    sys.exit(f"правка не применилась: {before!r} встречается {count} раз, нужен 1")
p.write_text(text.replace(before, after), encoding="utf-8")
PY
