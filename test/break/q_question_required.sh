#!/bin/sh
# Отрицательный контроль для claim'а needs-input-question-required.
#
# Что ломает: вопрос обязателен — в needs_input нельзя войти без текста
# вопроса. Правка убирает требование Question из перехода, и задача уходит
# ждать ответа, которого никто не задал: адресат не понимает, что от него
# хотят, а трекер не отличает такой случай от нормального вопроса.
#
# Ожидание: verifier (test/domain_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='      { permission = Anyone; requirements = [ Question; Addressee ] } );'
after='      { permission = Anyone; requirements = [ Addressee ] } );'

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
