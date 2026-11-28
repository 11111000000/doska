#!/bin/sh
# Отрицательный контроль для claim'а outbox-delivery.
#
# Что ломает: доставка не помечает уведомление sent — вызов mark_sent
# убран, и уведомление остаётся в очереди в состоянии pending: оно ушло
# адресату, но ушло бы и снова.
#
# Правка меняет поведение, а не сборку: ветка match остаётся
# исчерпывающей, поэтому предупреждение 8 (-warn-error +a) не превращает
# контроль в пустое доказательство.
#
# Ожидание: verifier (test/webhooks_test.exe) после этой правки падает.
set -eu
file=src/service/notify.ml
before='                    | Ok () ->
                        let* _ = Db.Repo_notification.mark_sent conn item.id in
                        loop (sent + 1) failed rest'
after='                    | Ok () ->
                        loop (sent + 1) failed rest'

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
