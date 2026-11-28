#!/bin/sh
# Сборка веб-приложения копированием: ядро уже собрано tsc (D4-R),
# бандлер не нужен — нативные ES-модули остаются собой. D3 вендорится
# файлом: единственная runtime-зависимость веба (ADR §6.4).
set -eu
cd "$(dirname "$0")"
cd ../../packages/core
npx tsc
cd ../../apps/web
python3 - <<'PY'
import shutil
shutil.rmtree('dist', ignore_errors=True)
PY
mkdir -p dist/core dist/vendor
cp index.html app.js tasks-view.js card-view.js board-view.js overview-view.js dist/
cp -r ../../packages/core/dist/src dist/core/src
cp ../../node_modules/d3/dist/d3.min.js dist/vendor/d3.min.js
echo "frontend/apps/web/dist готов"
