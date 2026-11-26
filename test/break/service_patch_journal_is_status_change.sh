#!/bin/sh
# Отрицательный контроль для claim'а service-patch-journal.
#
# Что ломает: правка задачи пишется в журнал как смена статуса. След перестаёт
# отвечать на вопрос «что изменилось»: и правка, и переход выглядят
# одинаково, а сводка изменённых полей пропадает.
#
# Якорь привязан к началу строки: с 21.11.2026 в src/service/task.ml два
# `Activity.Updated` — в правке задачи и в смене родителя. Без привязки к
# началу строки короткий якорь совпал бы и с более глубоко вложенным.
#
# Ожидание: verifier (test/service_task_test.exe) после этой правки падает.
set -eu

python3 - src/service/task.ml <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
before = "\n                  Db.Repo_activity.record conn ~action:Activity.Updated"
after = "\n                  Db.Repo_activity.record conn ~action:Activity.Status_changed"

text = path.read_text(encoding="utf-8")
count = text.count(before)
if count != 1:
    sys.exit(f"правка не применилась: якорь встречается {count} раз в {path}, нужен 1")
path.write_text(text.replace(before, after), encoding="utf-8")
PY
