#!/bin/sh
# CLI не имеет права врать о состоянии трекера: версия печатается из одного
# места, а health отвечает «ok» только когда база действительно отвечает.
#
# Живость проверяется в обе стороны: с живой базой — «ok», с недоступной —
# ошибка (§6.3, §9.1).
#
# Код возврата проверки всегда 1: слой доказательств отличает обычный отказ
# проверки от сбоя инфраструктуры, а поломка поведения — это отказ, а не авария.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

db_url=${DOSKA_DATABASE_URL:-postgresql:///doska}

# Недоступная база — тот же сервер, другое имя базы. Жёстко зашитый сокет
# работал бы только на машине разработчика: в CI postgres доступен по TCP, и
# проверка проходила бы вхолостую, по любой неработающей базе.
query=""
case "$db_url" in
  *\?*) query="?${db_url#*\?}"; db_url=${db_url%%\?*} ;;
esac

case "$db_url" in
  postgresql:///*) absent_db_url="postgresql:///doska_absent_cli_check" ;;
  */*) absent_db_url="${db_url%/*}/doska_absent_cli_check" ;;
  *) absent_db_url="postgresql:///doska_absent_cli_check" ;;
esac
absent_db_url="$absent_db_url$query"

if ! version=$(dune exec --root . src/bin/doska.exe -- version 2>&1); then
  echo "version: команда не отработала: $version" >&2
  exit 1
fi
case "$version" in
  "doska "?*) ;;
  *)
    echo "version: ожидалось «doska <версия>», получено «$version»" >&2
    exit 1
    ;;
esac

# База отвечает — health обязан сказать «ok».
if ! health=$(dune exec --root . src/bin/doska.exe -- health --db-url "$db_url" 2>&1); then
  echo "health: ожидалось «ok» при живой базе, получено «$health»" >&2
  exit 1
fi
if [ "$health" != "ok" ]; then
  echo "health: ожидалось «ok» при живой базе, получено «$health»" >&2
  exit 1
fi

# Базы нет — health обязан упасть, а не отрапортовать «ok».
if dune exec --root . src/bin/doska.exe -- health \
     --db-url "$absent_db_url" >/dev/null 2>&1; then
  echo "health: ожидалась ошибка при недоступной базе" >&2
  exit 1
fi

echo "cli: версия объявлена, health честен в обе стороны"
