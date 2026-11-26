#!/bin/sh
# Сборка веб-приложения копированием: ядро уже собрано tsc (D4-R),
# бандлер не нужен — нативные ES-модули остаются собой.
set -eu
cd "$(dirname "$0")"
cd ../../packages/core
npx tsc
cd ../../apps/web
python3 - <<'PY'
import shutil
shutil.rmtree('dist', ignore_errors=True)
PY
mkdir -p dist/core
cp index.html app.js tasks-view.js card-view.js dist/
cp -r ../../packages/core/dist/src dist/core/src
echo "frontend/apps/web/dist готов"
