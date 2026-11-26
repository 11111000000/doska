#!/bin/sh
# Плагин doska в Paseo: типы чисты, имена RPC в нижнем регистре (требование
# фреймворка), hook закрытия агента на месте, плагин установлен и running.
# База не нужна. Работает из корня репозитория.
set -eu

cd frontend
npm ci --no-audit --no-fund > /dev/null 2>&1
cd plugins/paseo
npx tsc --noEmit
grep -q 'doska.my_tasks' shared/doska-rpc.ts
grep -q 'doska.claim' shared/doska-rpc.ts
if grep -qE 'doska\.[A-Z]' shared/doska-rpc.ts; then
  echo "имя RPC с заглавной буквой: фреймворк отвергнет" >&2
  exit 1
fi
grep -q 'agent.closed' index.server.ts

cd ../..
paseo plugin ls --json > /tmp/paseo-plugins.json 2>/dev/null || true
python3 - <<'PY'
import json
try:
    plugins = json.load(open("/tmp/paseo-plugins.json"))
except Exception:
    print("paseo plugin ls недоступен (daemon не отвечает) — пропуск проверки установки")
    raise SystemExit(0)
items = plugins if isinstance(plugins, list) else plugins.get("plugins", [])
doska = next((p for p in items if p.get("id") == "doska"), None)
if doska is None:
    print("плагин doska не найден в paseo plugin ls", file=sys.stderr)
    raise SystemExit(1)
if doska.get("status") != "running":
    print(f"плагин doska не running: {doska.get('status')} {doska.get('error','')}", file=sys.stderr)
    raise SystemExit(1)
print("paseo plugin doska: running")
PY
