#!/bin/sh
# Проверка миграции источника актёра (migrations/003_actor_source.sql).
#
# Три независимых свойства:
#
#   columns   — у актора есть source и source_ref: без них импорт не знает,
#               откуда пришёл актёр (§10.2).
#   unique    — один внешний объект — одна строка: пара (source, source_ref)
#               уникальна, а актёры без источника (созданные вручную) этой
#               уникальности не касаются.
#   idempotent— файл можно применить повторно: и колонки, и индексы созданы
#               через IF NOT EXISTS.
#
# База берётся из DOSKA_DATABASE_URL. Скрипт создаёт отдельную временную
# базу на том же сервере, проверяет на ней и удаляет её — рабочая база
# разработчика не страдает.
#
# Использование: sh test/check_actor_source.sh

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
db="doska_source_$$"

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
for column in source source_ref; do
  found=$(psql "$url" -tAc \
    "SELECT count(*) FROM information_schema.columns \
     WHERE table_schema='public' AND table_name='actor' AND column_name='$column'")
  [ "$found" = "1" ] \
    || fail "у актора нет колонки $column"
done

# ------------------------------------------------------------------- unique ---
index=$(psql "$url" -tAc \
  "SELECT count(*) FROM pg_indexes \
   WHERE schemaname='public' AND indexname='actor_source_ref_uniq' AND indexdef LIKE '%UNIQUE%'")
[ "$index" = "1" ] \
  || fail "нет уникального индекса на паре (source, source_ref)"

# Актёры без источника (созданные вручную) в уникальность не попадают.
psql "$url" -q -v ON_ERROR_STOP=1 -c \
  "INSERT INTO actor (kind, handle, display_name) VALUES ('human', 'ручной-1', 'Ручной 1')" \
  >/dev/null || fail "актёр без источника не создался"
psql "$url" -q -v ON_ERROR_STOP=1 -c \
  "INSERT INTO actor (kind, handle, display_name) VALUES ('human', 'ручной-2', 'Ручной 2')" \
  >/dev/null || fail "второй актёр без источника не создался"

# Один и тот же внешний объект — одна строка.
psql "$url" -q -v ON_ERROR_STOP=1 -c \
  "INSERT INTO actor (kind, handle, display_name, source, source_ref) \
   VALUES ('human', 'из-источника-1', 'Из источника 1', 'test', 'u-1')" \
  >/dev/null || fail "актёр из источника не создался"

set +e
psql "$url" -q -v ON_ERROR_STOP=1 -c \
  "INSERT INTO actor (kind, handle, display_name, source, source_ref) \
   VALUES ('human', 'из-источника-2', 'Из источника 2', 'test', 'u-1')" \
  >/dev/null 2>&1
duplicate_status=$?
set -e
[ "$duplicate_status" -ne 0 ] \
  || fail "повторный импорт того же объекта создал вторую строку"

# Тот же source_ref из другого источника — другой объект.
psql "$url" -q -v ON_ERROR_STOP=1 -c \
  "INSERT INTO actor (kind, handle, display_name, source, source_ref) \
   VALUES ('human', 'из-другого-источника', 'Из другого источника', 'other', 'u-1')" \
  >/dev/null || fail "тот же ключ из другого источника не создался"

# --------------------------------------------------------------- idempotent ---
psql "$url" -q -v ON_ERROR_STOP=1 -f migrations/003_actor_source.sql >/dev/null \
  || fail "повторное применение миграции 003 должно проходить"
psql "$url" -q -v ON_ERROR_STOP=1 -f migrations/003_actor_source.sql >/dev/null \
  || fail "повторное применение миграции 003 должно проходить"

echo "OK (source)"
