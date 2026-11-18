#!/bin/sh
# Проверка собственного мигратора doska.
#
# Два независимых свойства, каждое проверяется своим режимом:
#
#   idempotent — применённый SQL можно применить повторно: ни дублей
#                таблиц, ни задвоенных типов. Это возможно только если
#                каждая конструкция файла идемпотентна.
#   immutable  — файл, который уже применён, менять нельзя: мигратор обязан
#                отказаться работать, а не согласиться продолжать. Иначе
#                база и репозиторий разойдутся молча, и расхождение
#                обнаружится уже на данных.
#
# База берётся из DOSKA_DATABASE_URL. Скрипт создаёт отдельную временную
# базу на том же сервере, проверяет на ней и удаляет её — рабочая база
# разработчика не страдает.
#
# Использование: sh test/check_migration.sh idempotent|immutable

set -eu

mode=${1:-}
case "$mode" in
  idempotent | immutable) ;;
  *)
    echo "нужен режим: idempotent или immutable" >&2
    exit 2
    ;;
esac

# База по умолчанию — та же, что у остальных проверок (test/support.ml,
# Db.Conn.default_uri). Слой доказательств запускает проверки в своём
# окружении, и требование явной переменной делало бы доказательство
# непроверяемым вне CI.
DOSKA_DATABASE_URL=${DOSKA_DATABASE_URL:-postgresql:///doska}
export DOSKA_DATABASE_URL

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# URL сервера без имени базы: к нему подключаемся как администратор.
server=${DOSKA_DATABASE_URL%/*}
admin="$server/postgres"
db="doska_check_$$"

cleanup() {
  dropdb --if-exists --maintenance-db="$admin" "$db" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

createdb --maintenance-db="$admin" "$db"
url="$server/$db"

# Сборка нужна и в чистой копии репозитория: тест не должен зависеть от
# того, что кто-то собрал бинарник заранее.
dune build --root . src/bin/doska.exe
doska() { dune exec --root . src/bin/doska.exe -- "$@"; }

fail() {
  echo "ПРОВАЛ ($mode): $1" >&2
  exit 1
}

# Сколько таблиц и типов ожидается в схеме doska.
# 11 доменных таблиц + schema_version.
expected_tables=12
# 9 типов-enum: actor_kind, actor_status, project_status, task_kind,
# task_status, task_priority, evidence_kind, link_kind, activity_action.
expected_types=9

case "$mode" in
  idempotent)
    doska migrate --db-url "$url" --migrations-dir migrations >/dev/null \
      || fail "первое применение миграции должно проходить"

    second=$(doska migrate --db-url "$url" --migrations-dir migrations)
    case "$second" in
      *"нечего применять"*) ;;
      *) fail "повторное применение должно быть пустым, получено: $second" ;;
    esac

    # Отметка о применении потеряна — сам SQL должен быть идемпотентным.
    psql "$url" -q -c "DELETE FROM schema_version" >/dev/null
    doska migrate --db-url "$url" --migrations-dir migrations >/dev/null \
      || fail "повторное применение SQL (при потерянной отметке) должно проходить"

    tables=$(psql "$url" -tAc \
      "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
    [ "$tables" = "$expected_tables" ] \
      || fail "после повторного применения ожидалось $expected_tables таблиц, получено $tables"

    types=$(psql "$url" -tAc \
      "SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace \
       WHERE n.nspname='public' AND t.typtype='e'")
    [ "$types" = "$expected_types" ] \
      || fail "после повторного применения ожидалось $expected_types типов, получено $types"

    # Каждый тип должен существовать в единственном экземпляре.
    duplicated=$(psql "$url" -tAc \
      "SELECT count(*) FROM (SELECT typname FROM pg_type t \
       JOIN pg_namespace n ON n.oid=t.typnamespace \
       WHERE n.nspname='public' AND t.typtype='e' \
       GROUP BY typname HAVING count(*) > 1) d")
    [ "$duplicated" = "0" ] \
      || fail "после повторного применения типы задвоились: $duplicated групп"
    ;;

  immutable)
    doska migrate --db-url "$url" --migrations-dir migrations >/dev/null \
      || fail "первое применение миграции должно проходить"

    # Тот же файл с тем же именем, но другим содержимым: мигратор обязан
    # заметить расхождение контрольной суммы и отказаться.
    tmp=$(mktemp -d)
    cp migrations/001_init.sql "$tmp/001_init.sql"
    printf '\n-- изменение после применения\n' >>"$tmp/001_init.sql"

    set +e
    output=$(doska migrate --db-url "$url" --migrations-dir "$tmp" 2>&1)
    status=$?
    set -e
    rm -rf "$tmp"

    [ "$status" -ne 0 ] \
      || fail "изменённый после применения файл должен отвергаться, а мигратор согласился продолжить"
    case "$output" in
      *"изменился после применения"*) ;;
      *) fail "мигратор отказался, но не сообщил причину: $output" ;;
    esac
    ;;
esac

echo "OK ($mode)"
