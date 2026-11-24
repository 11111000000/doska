#!/bin/sh
# Проверка миграции вопроса при needs_input (migrations/006_task_question.sql).
#
# Три независимых свойства:
#
#   columns — задача помнит вопрос, адресата и ответ: пять колонок в task,
#             адресат и автор ответа ссылаются на actor(id).
#   actions  — журнал умеет записывать «спросили» и «ответили»: в перечислении
#             activity_action есть значения questioned и answered.
#   idempotent — файл можно применить повторно: колонки добавлены через
#             IF NOT EXISTS, значения перечисления — тоже. Иначе повторное
#             развёртывание падало бы на уже применённой схеме.
#
# База берётся из DOSKA_DATABASE_URL. Скрипт создаёт отдельную временную
# базу на том же сервере, проверяет на ней и удаляет её — рабочая база
# разработчика не страдает.
#
# Использование: sh test/check_task_question_migration.sh

set -eu

DOSKA_DATABASE_URL=${DOSKA_DATABASE_URL:-postgresql:///doska}
export DOSKA_DATABASE_URL

# Повторное применение миграции — это ожидаемое поведение, а не замечание:
# сообщения PostgreSQL «already exists, skipping» молча гасим.
PGOPTIONS="-c client_min_messages=warning"
export PGOPTIONS

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# URL сервера без имени базы: к нему подключаемся как администратор.
server=${DOSKA_DATABASE_URL%/*}
admin="$server/postgres"
db="doska_question_mig_$$"

cleanup() {
  dropdb --if-exists --maintenance-db="$admin" "$db" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

createdb --maintenance-db="$admin" "$db"
url="$server/$db"

fail() {
  echo "ПРОВАЛ: $1" >&2
  exit 1
}

# Сборка нужна и в чистой копии репозитория: тест не должен зависеть от
# того, что кто-то собрал бинарник заранее.
dune build --root . src/bin/doska.exe
dune exec --root . src/bin/doska.exe -- migrate --db-url "$url" --migrations-dir migrations \
  >/dev/null || fail "миграции не применились"

# ------------------------------------------------------------------ columns ---
for column in question asked_to_id answer answered_at answered_by; do
  found=$(psql "$url" -tAc \
    "SELECT count(*) FROM information_schema.columns \
     WHERE table_schema='public' AND table_name='task' AND column_name='$column'")
  [ "$found" = "1" ] \
    || fail "у задачи нет колонки $column"
done

# Адресат вопроса и автор ответа — живые актёры: ссылка на actor(id).
for column in asked_to_id answered_by; do
  fk=$(psql "$url" -tAc \
    "SELECT count(*) FROM information_schema.key_column_usage k \
     JOIN information_schema.referential_constraints r \
       ON r.constraint_name=k.constraint_name AND r.constraint_schema=k.constraint_schema \
     WHERE k.table_schema='public' AND k.table_name='task' AND k.column_name='$column' \
       AND r.delete_rule='SET NULL'")
  [ "$fk" = "1" ] \
    || fail "колонка $column не ссылается на actor(id) с ON DELETE SET NULL"
done

# ------------------------------------------------------------------ actions ---
for action in questioned answered; do
  found=$(psql "$url" -tAc \
    "SELECT count(*) FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid \
     WHERE t.typname='activity_action' AND e.enumlabel='$action'")
  [ "$found" = "1" ] \
    || fail "в перечислении activity_action нет значения $action"
done

# --------------------------------------------------------------- idempotent ---
psql "$url" -q -v ON_ERROR_STOP=1 -f migrations/006_task_question.sql >/dev/null \
  || fail "повторное применение миграции 006 должно проходить"
psql "$url" -q -v ON_ERROR_STOP=1 -f migrations/006_task_question.sql >/dev/null \
  || fail "повторное применение миграции 006 должно проходить"

echo "OK (question migration)"
