#!/bin/sh
# Обвязка тестов не имеет права молчать: тест, которому нужна база, без базы
# обязан падать, а не «проходить мимо» (решение этапа 1: тесты живут на
# настоящей базе).
#
# Заведомо отсутствующая база строится из DOSKA_DATABASE_URL: тот же сервер,
# другое имя базы. Жёстко зашитый сокет работал бы только на машине
# разработчика: в CI postgres доступен по TCP, и проверка превращалась бы в
# «тест упал, но по другой причине» — она ничего не доказывала бы.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

db=${DOSKA_DATABASE_URL:-postgresql:///doska}

# Параметры запроса (?sslmode=...) сохраняем, меняем только имя базы.
query=""
case "$db" in
  *\?*) query="?${db#*\?}"; db=${db%%\?*} ;;
esac

case "$db" in
  postgresql:///*) absent="postgresql:///doska_absent_harness_check" ;;
  */*) absent="${db%/*}/doska_absent_harness_check" ;;
  *) absent="postgresql:///doska_absent_harness_check" ;;
esac
absent="$absent$query"

# С настоящей базой тест обязан проходить: иначе проверка ниже доказывала бы
# не то (например, падение из-за сломанной сборки, а не из-за отсутствия базы).
if ! DOSKA_DATABASE_URL="$db" dune exec --root . test/repo_test.exe >/dev/null 2>&1; then
  echo "repo_test не проходит с настоящей базой ($db): проверять нечего" >&2
  exit 1
fi

# Заведомо несуществующая база: настоящий тест обязан на этом споткнуться.
if DOSKA_DATABASE_URL="$absent" \
     dune exec --root . test/repo_test.exe >/dev/null 2>&1; then
  echo "repo_test прошёл без базы: обвязка подставила другую базу молча" >&2
  exit 1
fi

echo "tests: без базы тест падает, а не проходит мимо"
