#!/bin/sh
# Обвязка тестов не имеет права молчать: тест, которому нужна база, без базы
# обязан падать, а не «проходить мимо» (решение этапа 1: тесты живут на
# настоящей базе).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# Заведомо несуществующая база: настоящий тест обязан на этом споткнуться.
if DOSKA_DATABASE_URL=postgresql:///doska_absent_harness_check \
     dune exec --root . test/repo_test.exe >/dev/null 2>&1; then
  echo "repo_test прошёл без базы: обвязка подставила другую базу молча" >&2
  exit 1
fi

echo "tests: без базы тест падает, а не проходит мимо"
