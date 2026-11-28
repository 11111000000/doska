#!/bin/sh
# Сборка и целостность веб-приложения: зависимости из lockfile, dist
# собирается из исходников, index.html подключает входную точку, ядро,
# экраны и вендоренный D3 на месте. База не нужна.
# Работает из корня репозитория.
set -eu

cd frontend
npm ci --no-audit --no-fund > /dev/null 2>&1
cd apps/web
sh build.sh > /dev/null 2>&1
test -f dist/index.html
grep -q 'src="./app.js"' dist/index.html
grep -q 'groupByUrgency' dist/tasks-view.js
test -f dist/core/src/client.js
# Доска и обзор: файлы на месте, D3 вендорен (ADR §6.4 — единственная
# runtime-зависимость веба), обзор рисует через d3, доска зовёт переходы.
test -f dist/board-view.js
test -f dist/overview-view.js
test -s dist/vendor/d3.min.js
grep -q 'd3.min.js' dist/index.html
grep -q 'window.d3' dist/overview-view.js
grep -q 'transitionTask' dist/board-view.js
# Собранные модули должны грузиться: импорт и синтаксис — тоже контракт.
node --input-type=module -e "
import('./dist/board-view.js').then(() => import('./dist/overview-view.js')).then(
  () => console.log('модули доски и обзора грузятся'),
  (e) => { console.error(e); process.exit(1); },
);"
echo "frontend web: сборка, точка входа, доска и D3-обзор на месте"
