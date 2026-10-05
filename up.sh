#!/usr/bin/env bash
# OEM shippable edge: secrets, Mosquitto, asset node. Stops at "waiting for pairing".
#   ./up.sh      start and wait until every service is up
#   ./up.sh -r   docker compose down (containers and networks only), then start
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# shellcheck source=require-docker.sh
source "${ROOT}/require-docker.sh"

RECREATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--recreate)
      RECREATE=1
      shift
      ;;
    -h|--help)
      echo "Usage: ./up.sh [-r]"
      echo "  -r, --recreate  Remove containers and networks (docker compose down), then start."
      echo "                  Bind-mounted ./data and ./volumes are kept."
      exit 0
      ;;
    *)
      echo "Unknown argument: $1 (try ./up.sh -h)" >&2
      exit 1
      ;;
  esac
done

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

require_docker
./prepare.sh

if [[ "$RECREATE" -eq 1 ]]; then
  echo "==> Recreate: docker compose down (containers and networks only)"
  "$DOCKER" compose down
fi

dump_bad_logs() {
  local svc status
  while IFS=$'\t' read -r svc status; do
    [[ -z "$svc" ]] && continue
    case "$status" in
      Up*)
        [[ "$status" == *unhealthy* ]] || continue
        ;;
      "Exited (0)"*)
        continue
        ;;
    esac
    echo "----- logs: ${svc} (${status}) -----" >&2
    "$DOCKER" compose logs --tail 40 "$svc" >&2 || true
  done < <("$DOCKER" compose ps -a --format $'{{.Service}}\t{{.Status}}')
}

check_stack() {
  local svc status failed=0
  declare -A seen=()
  while IFS=$'\t' read -r svc status; do
    [[ -z "$svc" ]] && continue
    seen["$svc"]=1
    case "$status" in
      Up*)
        if [[ "$status" == *unhealthy* ]]; then
          echo "FAIL ${svc}: ${status}" >&2
          failed=1
        else
          echo "  ok ${svc}: ${status}"
        fi
        ;;
      "Exited (0)"*)
        echo "  ok ${svc}: ${status}"
        ;;
      *)
        echo "FAIL ${svc}: ${status}" >&2
        failed=1
        ;;
    esac
  done < <("$DOCKER" compose ps -a --format $'{{.Service}}\t{{.Status}}')

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    if [[ -z "${seen[$svc]:-}" ]]; then
      echo "FAIL ${svc}: not created" >&2
      failed=1
    fi
  done < <("$DOCKER" compose config --services)

  [[ "$failed" -eq 0 ]]
}

echo "==> Starting stack"
# The Pi keeps a local copy of the tag. Compose will not replace it unless we pull.
"$DOCKER" compose pull anx-inference
if ! "$DOCKER" compose up -d --wait --wait-timeout 180; then
  echo "Compose did not reach a running stack." >&2
  "$DOCKER" compose ps -a >&2 || true
  dump_bad_logs
  exit 1
fi
if ! check_stack; then
  echo "One or more services are not up." >&2
  dump_bad_logs
  exit 1
fi

echo ""
echo "Edge node is up. Services are running and waiting for pairing."
echo "Next, on this machine: start the robot sidecar (../asset-demo-pirobot-sidecar/up.sh)."
echo "Then pair with any one method: 1 manual ZIP, 2 USB, 3 Bluetooth, 4 pairing link."
echo "Pairing link (token and registry URL from the portal):"
echo "  curl -sS -X POST http://127.0.0.1:\${SERVER_PORT:-28480}/command/anx.asset.pairing.redeem \\"
echo "    -H 'content-type: application/json' \\"
echo "    -d '{\"command\":\"anx.asset.pairing.redeem\",\"payload\":{\"url\":\"https://REGISTRY_URL/api/public/asset-pairing/redeem\",\"token\":\"TOKEN\",\"role\":\"primary\"}}'"
echo "  Optional, private registry CA (file on the host: data/certs/registry-ca.crt):"
echo "    add \"caFile\":\"/app/local_data/certs/registry-ca.crt\" to payload"
echo "  Or skip TLS verification: add \"ignoreSslErrors\":true to payload"
