#!/bin/sh
# Проверка TypeScript-ядра: типы, контракты и логика.
#
# npm ci восстанавливает зависимости из package-lock.json, tsc собирает
# ядро (типы проверяются сборкой), node --test гоняет чистые функции
# и zod-схемы. Сборка обязательна: без неё node --test молча проходит
# на нуле тестов — пусто-зелёный не доказательство.
#
# Работает из корня репозитория.
set -eu

cd frontend/packages/core
npm ci --no-audit --no-fund > /dev/null 2>&1
npx tsc
test -f dist/test/urgency.test.js || {
  echo "тесты не собрались: нет dist/test/urgency.test.js" >&2
  exit 2
}
node --test "dist/test/*.test.js" > /dev/null
echo "frontend core: tsc чист, node --test зелёный"
