#!/bin/sh
# Снять состояние dune-daemon в дереве.
#
# Зачем: mathc копирует дерево (вместе с _build) для каждого
# отрицательного control'а. Если в _build лежит живой daemon, копия
# наследует его блокировку — и каждая сборка в копии висит на чужом
# daemon'е вместо того, чтобы просто собраться.
#
# После этой команды mathc идёт без зависаний.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
for name in .dune .db .digest-db .lock; do
  if [ -d "_build/$name" ]; then
    rm -rf "_build/$name"
  elif [ -f "_build/$name" ]; then
    rm -f "_build/$name"
  fi
done
echo "состояние dune-daemon снято"
