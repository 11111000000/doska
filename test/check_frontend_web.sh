#!/bin/sh
# Сборка и целостность веб-приложения: зависимости из lockfile, dist
# собирается из исходников, index.html подключает входную точку, ядро
# и экраны на месте. База не нужна. Работает из корня репозитория.
set -eu

cd frontend
npm ci --no-audit --no-fund > /dev/null 2>&1
cd apps/web
sh build.sh > /dev/null 2>&1
test -f dist/index.html
grep -q 'src="./app.js"' dist/index.html
grep -q 'groupByUrgency' dist/tasks-view.js
test -f dist/core/src/client.js
echo "frontend web: сборка и точка входа на месте"
