#!/bin/sh
# Отрицательный контроль для claim'а needs-input-addressee-required.
#
# Что ломает: адресат обязателен — вопрос без адресата некому адресовать.
# Правка убирает требование Addressee из перехода, и задача ждёт ответа от
# неизвестного человека: уведомление уходит в никуда, а очередь ответов
# копится без владельца.
#
# Ожидание: verifier (test/domain_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='      { permission = Anyone; requirements = [ Question; Addressee ] } );'
after='      { permission = Anyone; requirements = [ Question ] } );'

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
