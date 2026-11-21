#!/bin/sh
# Отрицательный контроль для claim'а api-parent-version.
#
# Что ломает: смена родителя меняет задачу, а значит ломает её оптимистичную
# блокировку — версия обязательна. Правка делает версию необязательной, и два
# клиента меняют родителя по очереди: второй затирает первого.
#
# Ожидание: verifier (test/api_test.exe) после этой правки падает.
set -eu

file=src/api/tasks.ml
before='      match Params.int_field body "version" with
      | None ->
          bad_request
            "нужно поле version: смена родителя защищена оптимистичной блокировкой"
      | Some version -> ('
after='      let version = Option.value (Params.int_field body "version") ~default:0 in
      ('

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
