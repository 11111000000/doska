#!/bin/sh
# Отрицательный контроль для claim'а needs-input-answerer.
#
# Что ломает: отвечать на вопрос может только человек — адресат, заявитель,
# руководитель или администратор. Правка открывает переход любому, и агент
# отвечает за человека: ответ, на который ждали живого человека, приходит
# без участия человека и выглядит как его решение.
#
# Ожидание: verifier (test/domain_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='      { permission = Answerer_or_supervisor; requirements = [ Answer ] } );'
after='      { permission = Anyone; requirements = [ Answer ] } );'

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
