#!/bin/sh
# Отрицательный контроль для claim'а service-assign-rule.
#
# Что ломает: доменное правило назначения ослабляется — агент получает
# право назначать задачу другому человеку. Отказ приходит как успех, и
# клиент не может отличить нарушение правила от разрешённого действия.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='      Error
        "агент не может назначать задачу другому человеку: право can_assign \
         появится вместе с учётными записями на этапе 2"'
after='      Ok ()'

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
