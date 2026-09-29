#!/usr/bin/env bash
# OEM shippable edge: secrets, Mosquitto, asset node. Stops at "waiting for pairing".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "  created .env from .env.example"
fi

ensure_profile() {
  local add="$1"
  local cur
  cur="$(grep -E '^COMPOSE_PROFILES=' .env | head -1 | cut -d= -f2- || true)"
  if echo ",${cur}," | grep -q ",${add},"; then
    return
  fi
  if [[ -z "$cur" ]]; then
    cur="$add"
  else
    cur="${cur},${add}"
  fi
  if grep -qE '^COMPOSE_PROFILES=' .env; then
    sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${cur}|" .env
  else
    echo "COMPOSE_PROFILES=${cur}" >> .env
  fi
  echo "  COMPOSE_PROFILES=${cur}"
}

# Single-asset edge, Mosquitto for the robot sidecar, and on-device inference.
ensure_profile registry-db
ensure_profile oem
ensure_profile inference

set_if_empty() {
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=$" .env 2>/dev/null || ! grep -qE "^${key}=" .env 2>/dev/null; then
    if grep -qE "^${key}=" .env 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
      echo "${key}=${val}" >> .env
    fi
  fi
}

# Host publishes only. Containers still listen on 8428 and 1880.
# 8428 and 1880 are often already taken on a robot.
if grep -qE '^VICTORIAMETRICS_PORT=8428$' .env; then
  sed -i 's|^VICTORIAMETRICS_PORT=8428$|VICTORIAMETRICS_PORT=38428|' .env
  echo "  VICTORIAMETRICS_PORT=38428 (host 8428 is left for whatever already holds it)"
fi
if grep -qE '^NODERED_PORT=1880$' .env; then
  sed -i 's|^NODERED_PORT=1880$|NODERED_PORT=31880|' .env
  echo "  NODERED_PORT=31880 (host 1880 is left for whatever already holds it)"
fi
if grep -qE '^NODERED_IO_PORT=1881$' .env; then
  sed -i 's|^NODERED_IO_PORT=1881$|NODERED_IO_PORT=31881|' .env
  echo "  NODERED_IO_PORT=31881 (host 1881 is left for whatever already holds it)"
fi

set_if_empty SINGLE_ASSET_MODE true
set_if_empty SINGLE_ASSET_DIR asset-local
set_if_empty OPERATION_MODE single_asset
set_if_empty COMPOSE_FILE "docker-compose.yml:docker-compose.inference.yml"

./prepare.sh
docker compose up -d

echo ""
echo "Edge node is up. Services are running and waiting for pairing."
echo "Next, on this machine: start the robot sidecar (../asset-demo-pirobot-sidecar/up.sh)."
echo "Then pair with any one method: 1 manual ZIP, 2 USB, 3 Bluetooth, 4 pairing link."
echo "Pairing link (token and registry URL from the portal):"
echo "  curl -sS -X POST http://127.0.0.1:\${SERVER_PORT:-28480}/command/anx.asset.pairing.redeem \\"
echo "    -H 'content-type: application/json' \\"
echo "    -d '{\"payload\":{\"url\":\"https://REGISTRY_URL/api/public/asset-pairing/redeem\",\"token\":\"TOKEN\",\"role\":\"primary\"}}'"
