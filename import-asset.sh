#!/usr/bin/env bash
# Apply a portal-generated ANX setup ZIP into this IPC example (one asset per host).
# Usage: ./import-asset.sh /path/to/setup.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ZIP="${1:-}"
if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
  echo "Usage: $0 /path/to/portal-setup.zip" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "Run ./prepare.sh first (creates .env)." >&2
  exit 1
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "==> Extracting $(basename "$ZIP")"
unzip -q -o "$ZIP" -d "$TMP"

# Locate package root (ZIP may have a single top-level folder)
PKG="$TMP"
if [[ ! -f "$PKG/docker-compose.yml" && ! -f "$PKG/.env" ]]; then
  # one top-level dir?
  count=0
  top=""
  for d in "$TMP"/*; do
    if [[ -d "$d" ]]; then
      count=$((count + 1))
      top="$d"
    fi
  done
  if [[ "$count" -eq 1 && -d "$top" ]]; then
    PKG="$top"
  fi
fi

if [[ ! -d "$PKG/local_data" && ! -f "$PKG/docker-compose.yml" ]]; then
  echo "ERROR: unrecognised portal package (expected local_data/ and/or docker-compose.yml)." >&2
  echo "Refuse to partially merge. Re-download from the portal setup wizard." >&2
  exit 1
fi

# One asset per IPC: refuse different asset id
EXISTING_REG="data/config/region-registration.yaml"
NEW_REG=""
if [[ -f "$PKG/local_data/config/region-registration.yaml" ]]; then
  NEW_REG="$PKG/local_data/config/region-registration.yaml"
fi

extract_asset_id() {
  local f="$1"
  # regionNode.assetId or assetsRegistryId
  grep -E '^\s*(assetId|assetsRegistryId):' "$f" 2>/dev/null | head -1 | sed -E 's/.*:\s*["'\'']?([^"'\'']+)["'\'']?/\1/' | tr -d '[:space:]' || true
}

if [[ -f "$EXISTING_REG" && -n "$NEW_REG" ]]; then
  old_id="$(extract_asset_id "$EXISTING_REG")"
  new_id="$(extract_asset_id "$NEW_REG")"
  if [[ -n "$old_id" && -n "$new_id" && "$old_id" != "$new_id" ]]; then
    echo "ERROR: this IPC already has asset id '${old_id}'; ZIP has '${new_id}'." >&2
    echo "One asset per IPC — use a fresh checkout or clear data/config/region-registration.yaml." >&2
    exit 1
  fi
fi

if [[ -n "$NEW_REG" ]]; then
  echo "  package type: prototype (includes region-registration.yaml)"
else
  echo "  package type: generic stack (no registration — use USB/BLE or a prototype ZIP later)"
fi

echo "==> Copying local_data into ./data"
mkdir -p data/config data/certs data/protocol_mappings
if [[ -d "$PKG/local_data/config" ]]; then
  cp -a "$PKG/local_data/config/." data/config/
fi
if [[ -d "$PKG/local_data/certs" ]]; then
  cp -a "$PKG/local_data/certs/." data/certs/
fi
if [[ -d "$PKG/local_data/protocol_mappings" ]]; then
  cp -a "$PKG/local_data/protocol_mappings/." data/protocol_mappings/
fi
# Prefer portal grafana/prometheus if present (prepare.sh already seeded defaults)
if [[ -d "$PKG/local_data/grafana" ]]; then
  mkdir -p data/grafana
  cp -a "$PKG/local_data/grafana/." data/grafana/
fi
if [[ -d "$PKG/local_data/prometheus" ]]; then
  mkdir -p data/prometheus
  cp -a "$PKG/local_data/prometheus/." data/prometheus/
  # Fix known wrong scrape target if portal ZIP still has :9090
  if [[ -f data/prometheus/prometheus.yml ]]; then
    sed -i "s|anx-assets-node:9090|anx-assets-node:\${INTERNAL_PORT:-8081}|g" data/prometheus/prometheus.yml || true
    # If sed left literal ${...} broken, rewrite internal port from .env
    # shellcheck disable=SC1091
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
    sed -i "s|anx-assets-node:\${INTERNAL_PORT:-8081}|anx-assets-node:${INTERNAL_PORT:-8081}|g" data/prometheus/prometheus.yml || true
    sed -i "s|targets: \['anx-assets-node:9090'\]|targets: ['anx-assets-node:${INTERNAL_PORT:-8081}']|g" data/prometheus/prometheus.yml || true
  fi
fi
if [[ -d "$PKG/local_data/mqtt" ]]; then
  mkdir -p data/mqtt
  cp -a "$PKG/local_data/mqtt/." data/mqtt/
fi

echo "==> Merging portal .env keys (secrets preserved)"
PORTAL_ENV=""
if [[ -f "$PKG/.env" ]]; then
  PORTAL_ENV="$PKG/.env"
elif [[ -f "$PKG/anx.env" ]]; then
  PORTAL_ENV="$PKG/anx.env"
fi

merge_key() {
  local key="$1"
  local val="$2"
  # Never overwrite secrets
  case "$key" in
    POSTGRES_PASSWORD|MONGO_ROOT_PASSWORD|MONGO_INITDB_ROOT_PASSWORD|REDIS_PASSWORD|GRAFANA_ADMIN_PASSWORD|GF_SECURITY_ADMIN_PASSWORD)
      echo "  skip secret $key"
      return
      ;;
  esac
  if grep -qE "^${key}=" .env 2>/dev/null; then
    # escape sed specials in val minimally
    local esc
    esc="$(printf '%s' "$val" | sed -e 's/[\/&]/g\\&')"
    sed -i "s|^${key}=.*|${key}=${esc}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
  echo "  set ${key}"
}

if [[ -n "$PORTAL_ENV" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
      # strip surrounding quotes
      v="${v%\"}"
      v="${v#\"}"
      v="${v%\'}"
      v="${v#\'}"
      case "$k" in
        SINGLE_ASSET_DIR|SINGLE_ASSET_MODE|OPERATION_MODE|SERVER_PORT|INTERNAL_PORT|GRPC_PORT|WEBSOCKET_PORT|\
        ANX_ASSET_INSTANCE_ID|ANX_ASSET_NAME|ANX_REGION_SLUG|ANX_REGISTRATION_CODE|ANX_ENVIRONMENT|\
        LOCAL_DATA_PATH|RUST_LOG|VICTORIAMETRICS_URL|ANX_USB_ASSET_INIT_ROOT|\
        POSTGRES_USER|POSTGRES_DB|POSTGRES_DATABASE|MONGO_*|REDIS_PORT|MQTT_*|NODERED_*|LOKI_*|\
        GRAFANA_PORT|PROMETHEUS_*|NODE_EXPORTER_*)
          merge_key "$k" "$v"
          ;;
      esac
    fi
  done < "$PORTAL_ENV"
else
  echo "  no portal .env found — keeping example .env"
fi

echo "==> Compose override from portal docker-compose.yml (devices / custom services / host network)"
OVERRIDE="docker-compose.override.yml"
if [[ -f "$PKG/docker-compose.yml" ]]; then
  COMPOSE="$PKG/docker-compose.yml"
  # Recognisable ANX generate-package compose
  if ! grep -q 'anx-assets-node' "$COMPOSE"; then
    echo "ERROR: portal docker-compose.yml has no anx-assets-node service — refuse to merge." >&2
    exit 1
  fi

  NEED_OVERRIDE=0
  if grep -qE 'network_mode:\s*host' "$COMPOSE"; then NEED_OVERRIDE=1; fi
  if grep -qE '^\s+devices:' "$COMPOSE"; then NEED_OVERRIDE=1; fi
  # custom containers besides the standard stack names
  EXTRA_SVCS="$(grep -E '^[a-zA-Z0-9_-]+:' "$COMPOSE" | sed 's/://' | grep -Ev '^(anx-assets-node|victoriametrics|postgres|mongodb|redis|grafana|prometheus|node-exporter|mqtt|nodered|loki|anx-orchestrator|services|networks|volumes)$' || true)"
  if [[ -n "$EXTRA_SVCS" ]]; then NEED_OVERRIDE=1; fi

  if [[ "$NEED_OVERRIDE" -eq 1 ]]; then
    {
      echo "# Generated by import-asset.sh from portal ZIP — review before production use."
      echo "# Compose merges this with docker-compose.yml automatically."
      echo "services:"
      echo "  anx-assets-node:"
      if grep -qE 'network_mode:\s*host' "$COMPOSE"; then
        echo "    network_mode: host"
        echo "  # NOTE: host network drops published ports; reach REST/internal on the host IP."
      fi
      # Extract devices block under anx-assets-node if present (best-effort)
      if grep -qE '^\s+devices:' "$COMPOSE"; then
        echo "    devices:"
        # Rough extract: lines after "devices:" until next non-indented-list key
        awk '
          /^  anx-assets-node:/ { in_node=1; next }
          in_node && /^  [a-zA-Z0-9_-]+:/ && !/^  anx-assets-node:/ { in_node=0 }
          in_node && /^    devices:/ { in_dev=1; next }
          in_dev && /^      - / { print "      " $0; next }
          in_dev && /^    [a-zA-Z]/ { in_dev=0 }
        ' "$COMPOSE" | sed 's/^            - /      - /'
      fi
    } > "$OVERRIDE"

    # Append extra services as a note if we cannot safely copy full YAML
    if [[ -n "$EXTRA_SVCS" ]]; then
      echo "" >> "$OVERRIDE"
      echo "# Extra portal services detected (add manually if needed):" >> "$OVERRIDE"
      while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        echo "#   - $s" >> "$OVERRIDE"
      done <<< "$EXTRA_SVCS"
      echo "WARN: portal ZIP defines extra services ($(echo "$EXTRA_SVCS" | tr '\n' ' '))." >&2
      echo "      Listed as comments in ${OVERRIDE} — copy their blocks from the portal compose if required." >&2
    fi
    echo "  wrote ${OVERRIDE}"
  else
    rm -f "$OVERRIDE"
    echo "  no devices / host network / custom services — override not needed"
  fi
else
  echo "  no docker-compose.yml in ZIP — skip override"
fi

echo ""
echo "Import complete. Start or restart:"
echo "  docker compose up -d"
echo "If the node was already running, restart so it reloads config:"
echo "  docker compose restart anx-assets-node"
