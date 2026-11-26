#!/bin/sh
# Отрицательный контроль для claim'а needs-input-answer-required.
#
# Что ломает: выход из needs_input требует ответа. Правка убирает требование
# Answer из перехода, и задача возвращается в работу без ответа: вопрос
# остаётся без ответа в истории, а следующий читатель не видит, чем задача
# закончилась.
#
# Ожидание: verifier (test/domain_test.exe) после этой правки падает.
set -eu

file=src/domain/rules.ml
before='      { permission = Answerer_or_supervisor; requirements = [ Answer ] } );'
after='      { permission = Answerer_or_supervisor; requirements = [] } );'

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
