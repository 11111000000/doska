#!/bin/sh
# Проверка TypeScript-ядра: типы, контракты и логика.
#
# npm ci восстанавливает зависимости из package-lock.json (сеть нужна
# один раз на прогон), строгий tsc проверяет типы, node --test гоняет
# чистые функции и zod-схемы. База не нужна.
#
# Работает из корня репозитория.
set -eu

cd frontend/packages/core
npm ci --no-audit --no-fund > /dev/null 2>&1
npx tsc --noEmit
node --test "dist/test/*.test.js" > /dev/null
echo "frontend core: tsc чист, node --test зелёный"
