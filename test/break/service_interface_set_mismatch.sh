#!/bin/sh
# Отрицательный контроль для claim'а service-interface-set.
#
# Что ломает: набор интерфейсов в базе расходится с доменом. Правка убирает
# из ограничения одно значение — база принимает и отвергает не то, что умеет
# читать домен, и журнал может получить интерфейс, который никто не прочитает.
#
# Ожидание: verifier (test/check_service_layer.sh) после этой правки падает.
set -eu

file=migrations/005_activity_interface_check.sql
before="'mattermost','paseo','import','system'))"
after="'mattermost','import','system'))"

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
