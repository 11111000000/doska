#!/bin/sh
# Проверка архитектурных свойств сервисного слоя (D5).
#
# 1. Правила задач и транзакции над ними живут в сервисном слое, а HTTP-слой —
#    адаптер: разобрал запрос, вызвал сервис, перевёл отказ в код ответа. Если
#    правило или запись в базу вернутся в обработчик, REST, MCP и CLI начнут
#    вести себя по-разному: правило перестанет быть одним.
# 2. Набор интерфейсов один и тот же в домене и в базе: домен читает то, что
#    база разрешает записать, иначе журнал примет значение, которого никто не
#    умеет прочитать.
#
# Проверка статическая: она ловит именно переезд правил в адаптер и расхождение
# наборов интерфейсов.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

adapter=src/api/tasks.ml
service=src/service/task.ml
auth=src/api/auth.ml
interface=src/domain/interface.ml
check=migrations/005_activity_interface_check.sql

fail () {
  echo "$1" >&2
  exit 1
}

# В адаптере не должно быть ни проверки правил домена, ни прямых записей:
# это работа use case'а, а не обработчика.
for forbidden in \
  'Rules.check' \
  'Rules.may_assign' \
  'Db.Repo_task.set_status' \
  'Db.Repo_task.set_assignee' \
  'Db.Repo_task.update' \
  'Db.Repo_task.add_comment' \
  'Db.Repo_evidence.add'
do
  if grep -q -- "$forbidden" "$adapter"; then
    fail "$adapter: $forbidden — правила и записи задач должны жить в сервисном слое"
  fi
done

# Право администратора — тоже не дело HTTP-слоя: сервис решает по нему, может ли
# агент закрыть задачу сам.
for forbidden in \
  'let admin_handles' \
  'let is_admin'
do
  if grep -q -- "$forbidden" "$auth"; then
    fail "$auth: $forbidden — проверка администратора должна жить в слое идентичности"
  fi
done

# В сервисе правила применяются: без них use case'ы не работают.
grep -q 'Rules.check' "$service" ||
  fail "$service: нет проверки правил домена"
grep -q 'Rules.may_assign' "$service" ||
  fail "$service: нет правила назначения"
grep -q 'Identity.Admin.is_admin' "$service" ||
  fail "$service: право администратора не запрашивается у слоя идентичности"

# Адаптер обязан звать сервис, а не обходить его.
grep -q 'Service.Task\.' "$adapter" ||
  fail "$adapter: сервис задач не вызывается"

# Набор интерфейсов домена и базы — один и тот же список.
python3 - "$interface" "$check" <<'PY' || exit 1
import pathlib
import re
import sys

domain = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
db = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

# Домен: значения, которые он умеет читать (ветви of_string).
match = re.search(r"let of_string : string -> t option = function(.*?)\| _ -> None", domain, re.S)
if not match:
    print("домен: не найден разбор of_string — нечем сверять набор", file=sys.stderr)
    sys.exit(1)
in_domain = set(re.findall(r"\"([a-z_]+)\"", match.group(1)))

# База: значения, которые ограничение разрешает записать.
match = re.search(r"CHECK \(interface IN \((.*?)\)\)", db, re.S)
if not match:
    print("база: не найдено ограничение activity.interface — набор не зафиксирован", file=sys.stderr)
    sys.exit(1)
in_db = set(re.findall(r"'([a-z_]+)'", match.group(1)))

if in_domain != in_db:
    only_domain = ", ".join(sorted(in_domain - in_db)) or "—"
    only_db = ", ".join(sorted(in_db - in_domain)) or "—"
    print(
        f"наборы интерфейсов разошлись: только в домене ({only_domain}); "
        f"только в базе ({only_db})",
        file=sys.stderr,
    )
    sys.exit(1)
PY

echo "service layer: правила и записи задач живут в $service; набор интерфейсов домена и базы совпадает"
