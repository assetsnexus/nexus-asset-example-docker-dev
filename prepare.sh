#!/usr/bin/env bash
# Prepare an ANX asset IPC host: secrets, database.yaml, Grafana/Prometheus provisioning, init probes.
# Full Edge AI: ./prepare.sh --with-inference
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WITH_INFERENCE=false
for arg in "$@"; do
  case "$arg" in
    --with-inference) WITH_INFERENCE=true ;;
    -h|--help)
      echo "Usage: ./prepare.sh [--with-inference]"
      echo "  --with-inference  Enable registry-db + inference profiles, local trust token, .env.inference"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

set_env_in_file() {
  local file="$1"
  local key="$2"
  local val="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    local esc
    esc=$(printf '%s' "$val" | sed -e 's/[&|\\]/\\&/g')
    sed -i "s|^${key}=.*|${key}=${esc}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

set_env_if_empty() {
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=$" .env 2>/dev/null || ! grep -qE "^${key}=" .env 2>/dev/null; then
    if grep -qE "^${key}=" .env 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
      echo "${key}=${val}" >> .env
    fi
    echo "  generated ${key}"
  elif grep -qE "^${key}=.+" .env 2>/dev/null; then
    echo "  kept existing ${key}"
  fi
}

set_inference_env_if_empty() {
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=$" .env.inference 2>/dev/null || ! grep -qE "^${key}=" .env.inference 2>/dev/null; then
    set_env_in_file .env.inference "$key" "$val"
    echo "  inference: set ${key}"
  elif grep -qE "^${key}=.+" .env.inference 2>/dev/null; then
    local cur
    cur=$(grep -E "^${key}=" .env.inference | head -1 | cut -d= -f2-)
    if [[ "$cur" == *"CHANGE_ME"* || -z "$cur" ]]; then
      set_env_in_file .env.inference "$key" "$val"
      echo "  inference: refreshed ${key}"
    else
      echo "  inference: kept existing ${key}"
    fi
  fi
}

merge_compose_profile() {
  local add="$1"
  local cur="${COMPOSE_PROFILES:-}"
  if [[ -z "$cur" ]]; then
    COMPOSE_PROFILES="$add"
    return
  fi
  if echo ",${cur}," | grep -q ",${add},"; then
    return
  fi
  COMPOSE_PROFILES="${cur},${add}"
}

echo "==> ANX asset IPC prepare"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "  created .env from .env.example"
else
  echo "  using existing .env"
fi

if [[ ! -f .env.inference ]]; then
  cp .env.inference.example .env.inference
  echo "  created .env.inference from example"
fi

# Honor COMPOSE_PROFILES already containing inference
# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source .env
set +a

if echo ",${COMPOSE_PROFILES:-}," | grep -q ",inference,"; then
  WITH_INFERENCE=true
fi

if [[ "$WITH_INFERENCE" == true ]]; then
  echo "==> Edge AI (--with-inference)"
  merge_compose_profile "registry-db"
  merge_compose_profile "inference"
  set_env_in_file .env COMPOSE_PROFILES "$COMPOSE_PROFILES"
  echo "  COMPOSE_PROFILES=${COMPOSE_PROFILES}"
  set_env_in_file .env ANX_EDGE_INFERENCE_URL "http://anx-inference:3055"
  set_env_in_file .env ANX_EDGE_LOCAL_TOKEN_FILE "/app/local_data/edge/local-trust.token"
fi

echo "==> Secrets (empty values only)"
set_env_if_empty POSTGRES_PASSWORD "$(gen_secret)"
set_env_if_empty MONGO_ROOT_PASSWORD "$(gen_secret)"
set_env_if_empty REDIS_PASSWORD "$(gen_secret)"
set_env_if_empty GRAFANA_ADMIN_PASSWORD "$(gen_secret)"
set_env_if_empty MQTT_PASSWORD "$(gen_secret)"

# Keep Grafana GF_* in sync with GRAFANA_* when GF is empty
# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source .env
set +a

if [[ -z "${GF_SECURITY_ADMIN_PASSWORD:-}" && -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  set_env_if_empty GF_SECURITY_ADMIN_PASSWORD "$GRAFANA_ADMIN_PASSWORD"
fi
if [[ -z "${GF_SECURITY_ADMIN_USER:-}" ]]; then
  set_env_if_empty GF_SECURITY_ADMIN_USER "${GRAFANA_ADMIN_USER:-admin}"
fi

# Fail if critical secrets still empty after generation
# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source .env
set +a

missing=0
for k in POSTGRES_PASSWORD MONGO_ROOT_PASSWORD REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD; do
  eval "v=\${$k:-}"
  if [[ -z "$v" ]]; then
    echo "ERROR: $k is still empty" >&2
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

PROFILES="${COMPOSE_PROFILES:-}"
has_profile() {
  echo ",${PROFILES}," | grep -q ",$1,"
}

if has_profile state || has_profile registry || has_profile registry-db; then
  set_env_if_empty ANX_REDIS_URL "redis://:${REDIS_PASSWORD}@redis:6379"
  if command -v openssl >/dev/null 2>&1; then
    set_env_if_empty ANX_REDIS_DATA_KEY "$(openssl rand -base64 32)"
  else
    set_env_if_empty ANX_REDIS_DATA_KEY "$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  fi
  if has_profile registry; then
    set_env_if_empty OPERATION_MODE "multi_tenant"
  fi
fi

if [[ "$WITH_INFERENCE" == true ]]; then
  mkdir -p data/edge
  TOKEN_FILE=data/edge/local-trust.token
  if [[ ! -s "$TOKEN_FILE" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 32 > "$TOKEN_FILE"
    else
      head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE"
    fi
    chmod 600 "$TOKEN_FILE" || true
    echo "  wrote ${TOKEN_FILE} (local trust; not printed)"
  else
    echo "  kept existing ${TOKEN_FILE}"
  fi

  MONGO_USER="${MONGO_ROOT_USERNAME:-admin}"
  MONGO_PASS="${MONGO_ROOT_PASSWORD}"
  MONGODB_URI="mongodb://${MONGO_USER}:${MONGO_PASS}@mongodb:27017/anx_inference?authSource=admin"

  set_inference_env_if_empty ANX_INFERENCE_MODE "asset_edge"
  set_inference_env_if_empty ANX_ASSETS_NODE_URL "http://anx-assets-node:${SERVER_PORT:-28480}"
  set_inference_env_if_empty ANX_EDGE_LOCAL_TOKEN_FILE "/edge/local-trust.token"
  set_inference_env_if_empty APP_HOST "0.0.0.0"
  set_inference_env_if_empty APP_PORT "${ANX_INFERENCE_PORT:-3055}"
  set_env_in_file .env.inference MONGODB_URI "$MONGODB_URI"
  echo "  inference: set MONGODB_URI (from .env Mongo credentials)"
  set_env_in_file .env.inference REDIS_HOST "redis"
  set_env_in_file .env.inference REDIS_PORT "6379"
  set_env_in_file .env.inference REDIS_PASSWORD "$REDIS_PASSWORD"
  echo "  inference: set REDIS_* (from .env)"
  set_env_in_file .env.inference SCYLLA_ENABLED "false"
  set_inference_env_if_empty JWT_ACCESS_SECRET "$(gen_secret)$(gen_secret)"
  set_inference_env_if_empty JWT_REFRESH_SECRET "$(gen_secret)$(gen_secret)"

  set_env_if_empty MINIO_ROOT_USER "anx"
  set_env_if_empty MINIO_ROOT_PASSWORD "$(gen_secret)"
  # shellcheck disable=SC1091
  source .env
  set_env_in_file .env.inference MINIO_ROOT_USER "${MINIO_ROOT_USER}"
  set_env_in_file .env.inference MINIO_ROOT_PASSWORD "${MINIO_ROOT_PASSWORD}"
  set_env_in_file .env.inference S3_ENDPOINT "http://minio:9000"
  set_env_in_file .env.inference S3_FORCE_PATH_STYLE "true"
  set_env_in_file .env.inference S3_BUCKET "inference"
  set_env_in_file .env.inference AWS_ACCESS_KEY_ID "${MINIO_ROOT_USER}"
  set_env_in_file .env.inference AWS_SECRET_ACCESS_KEY "${MINIO_ROOT_PASSWORD}"
  set_env_in_file .env.inference AWS_REGION "us-east-1"
  echo "  inference: set MinIO/S3 credentials (password not printed)"

  # Compose image: substitution reads .env only. .env.inference is container env.
  PUBLISHED_INFERENCE_IMAGE="eu1.dockerreg.sdk.assetsnexus.org/nexus/inference/anx.inference.backend"
  cur_image="$(grep -E '^ANX_INFERENCE_IMAGE=' .env.inference | head -1 | cut -d= -f2- || true)"
  if [[ -z "$cur_image" || "$cur_image" == "eu1.dockerreg.sdk.assetsnexus.org/anx-inference-backend" ]]; then
    set_env_in_file .env.inference ANX_INFERENCE_IMAGE "$PUBLISHED_INFERENCE_IMAGE"
    cur_image="$PUBLISHED_INFERENCE_IMAGE"
  fi
  cur_tag="$(grep -E '^ANX_INFERENCE_TAG=' .env.inference | head -1 | cut -d= -f2- || true)"
  if [[ -z "$cur_tag" || "$cur_tag" == "latest" ]]; then
    set_env_in_file .env.inference ANX_INFERENCE_TAG "0.1.3"
    cur_tag="0.1.3"
  fi
  set_env_in_file .env ANX_INFERENCE_IMAGE "$cur_image"
  set_env_in_file .env ANX_INFERENCE_TAG "$cur_tag"
  echo "  inference image: ${cur_image}:${cur_tag}"
  mkdir -p volumes/minio
fi

echo "==> data/config/database.yaml (enabled flags match COMPOSE_PROFILES)"
mkdir -p data/config data/certs data/protocol_mappings data/edge data/grafana/provisioning/datasources \
  data/grafana/provisioning/dashboards data/grafana/dashboards data/prometheus data/mqtt

# Persistent service data under ./volumes (bind mounts — not Docker named volumes)
mkdir -p \
  volumes/victoriametrics \
  volumes/postgres \
  volumes/mongodb/data \
  volumes/mongodb/config \
  volumes/redis \
  volumes/grafana \
  volumes/prometheus \
  volumes/mqtt/data \
  volumes/mqtt/log \
  volumes/nodered \
  volumes/nodered-io \
  volumes/loki
echo "  ensured volumes/{victoriametrics,postgres,mongodb,redis,grafana,prometheus,mqtt,nodered,nodered-io,loki}"

if has_profile oem || has_profile oem-io; then
  # shellcheck disable=SC1091
  source .env
  if [[ -n "${MQTT_PASSWORD:-}" ]]; then
    if command -v mosquitto_passwd >/dev/null 2>&1; then
      mosquitto_passwd -b -c data/mqtt/passwd anx "${MQTT_PASSWORD}"
      echo "  wrote data/mqtt/passwd for user anx"
    else
      echo "WARN: mosquitto_passwd not on host. Install mosquitto-clients and rerun prepare, or:" >&2
      echo "  docker run --rm -v \"\$PWD/data/mqtt:/cfg\" eclipse-mosquitto:2 mosquitto_passwd -b -c /cfg/passwd anx \"\$MQTT_PASSWORD\"" >&2
    fi
  fi

  # TLS CA + broker cert for Mosquitto 8883 (never commit data/mqtt/certs or private keys).
  mkdir -p data/mqtt/certs
  if [[ ! -f data/mqtt/certs/ca.crt || ! -f data/mqtt/certs/broker.crt || ! -f data/mqtt/certs/broker.key ]]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout data/mqtt/certs/ca.key -out data/mqtt/certs/ca.crt -subj "/CN=anx-ipc-mqtt-ca" 2>/dev/null
      openssl req -newkey rsa:2048 -nodes \
        -keyout data/mqtt/certs/broker.key -out data/mqtt/certs/broker.csr -subj "/CN=localhost" 2>/dev/null
      printf 'subjectAltName=DNS:localhost,DNS:mqtt,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' > data/mqtt/certs/broker.ext
      openssl x509 -req -in data/mqtt/certs/broker.csr \
        -CA data/mqtt/certs/ca.crt -CAkey data/mqtt/certs/ca.key -CAcreateserial \
        -out data/mqtt/certs/broker.crt -days 825 -extfile data/mqtt/certs/broker.ext 2>/dev/null
      rm -f data/mqtt/certs/broker.csr data/mqtt/certs/broker.ext
      chmod 600 data/mqtt/certs/ca.key data/mqtt/certs/broker.key || true
      echo "  generated data/mqtt/certs (ca.crt + broker cert; private keys not printed)"
    else
      echo "WARN: openssl missing — cannot generate MQTT TLS certs under data/mqtt/certs" >&2
    fi
  else
    echo "  kept existing data/mqtt/certs"
  fi

  set_env_if_empty MQTT_BROKER "mqtts://127.0.0.1:28883"
  set_env_if_empty MQTT_CA_FILE "/app/local_data/mqtt/certs/ca.crt"
  set_env_if_empty MQTT_TLS_PORT "28883"
fi

REG_DB=false
has_profile registry-db && REG_DB=true

cat > data/config/database.yaml <<EOF
# Generated by prepare.sh — do not hand-edit unless you know the profile set.
database:
  instances:
    - name: victoriametrics-primary
      type: victoriametrics
      enabled: true
      hosts:
        - host: victoriametrics
          port: 8428
      connectionMode: round_robin
      victoriametrics:
        url: http://victoriametrics:8428
    - name: postgresql-primary
      type: postgresql
      enabled: ${REG_DB}
      hosts:
        - host: postgres
          port: 5432
          username: ${POSTGRES_USER:-postgres}
          password: "\${POSTGRES_PASSWORD}"
          database: ${POSTGRES_DATABASE:-anx_assets}
      connectionMode: round_robin
      postgresql:
        url: postgresql://${POSTGRES_USER:-postgres}:\${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DATABASE:-anx_assets}
    - name: mongodb-primary
      type: mongodb
      enabled: ${REG_DB}
      hosts:
        - host: mongodb
          port: 27017
          username: ${MONGO_ROOT_USERNAME:-admin}
          password: "\${MONGO_ROOT_PASSWORD}"
          database: ${MONGO_DATABASE:-anx-asset}
      connectionMode: round_robin
      mongodb:
        authSource: admin
    - name: redis-primary
      type: redis
      enabled: ${REG_DB}
      hosts:
        - host: redis
          port: 6379
          password: "\${REDIS_PASSWORD}"
      connectionMode: round_robin
      redis:
        db: 0
        keyPrefix: anx:
EOF
echo "  wrote data/config/database.yaml (registry-db=${REG_DB})"

if [[ ! -f data/config/general.yml ]]; then
  cat > data/config/general.yml <<EOF
mode: SingleAsset
single_asset_dir: ${SINGLE_ASSET_DIR:-asset-local}
server:
  host: "0.0.0.0"
  port: ${SERVER_PORT:-28480}
  internal_port: ${INTERNAL_PORT:-28481}
  grpc_port: ${GRPC_PORT:-25051}
  websocket_port: ${WEBSOCKET_PORT:-28482}
victoriametrics:
  url: ${VICTORIAMETRICS_URL:-http://victoriametrics:8428}
  buffer_size: 10000
  flush_interval_secs: 10
prometheus:
  enabled: true
  port: 9090
frontend:
  admin_username: admin
  admin_password: admin
  port: 3000
EOF
  echo "  wrote data/config/general.yml (default; import-asset.sh may overwrite)"
fi
# The node enum is SingleAsset / MultiTenant. OPERATION_MODE in .env stays single_asset.
if [[ -f data/config/general.yml ]] && grep -q '^mode: single_asset$' data/config/general.yml; then
  sed -i 's|^mode: single_asset$|mode: SingleAsset|' data/config/general.yml
  echo "  general.yml mode set to SingleAsset"
fi

echo "==> Prometheus scrape config"
cat > data/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: node-exporter
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: anx-assets-node
    metrics_path: /metrics
    static_configs:
      - targets: ['anx-assets-node:${INTERNAL_PORT:-28481}']

  - job_name: victoriametrics
    static_configs:
      - targets: ['victoriametrics:8428']
EOF

echo "==> Grafana provisioning"
mkdir -p data/grafana/provisioning/datasources data/grafana/provisioning/dashboards data/grafana/dashboards

DS_FILE=data/grafana/provisioning/datasources/anx-stack.yml
{
  echo 'apiVersion: 1'
  echo 'datasources:'
  echo '  - name: VictoriaMetrics'
  echo '    type: prometheus'
  echo '    access: proxy'
  echo '    url: http://victoriametrics:8428'
  echo '    isDefault: true'
  echo '    jsonData:'
  echo '      httpMethod: POST'
  echo '  - name: Prometheus'
  echo '    type: prometheus'
  echo '    access: proxy'
  echo '    url: http://prometheus:9090'
  echo '    isDefault: false'
  echo '    jsonData:'
  echo '      httpMethod: POST'
  if has_profile registry-db; then
    echo '  - name: Postgres'
    echo '    type: postgres'
    echo '    access: proxy'
    echo "    url: postgres:5432"
    echo "    user: ${POSTGRES_USER:-postgres}"
    echo '    secureJsonData:'
    echo "      password: ${POSTGRES_PASSWORD}"
    echo '    jsonData:'
    echo "      database: ${POSTGRES_DATABASE:-anx_assets}"
    echo '      sslmode: disable'
    echo '      postgresVersion: 1600'
  fi
  if has_profile logs; then
    echo '  - name: Loki'
    echo '    type: loki'
    echo '    access: proxy'
    echo '    url: http://loki:3100'
    echo '    isDefault: false'
  fi
} > "$DS_FILE"

cat > data/grafana/provisioning/dashboards/anx.yml <<'EOF'
apiVersion: 1
providers:
  - name: ANX
    orgId: 1
    folder: ANX
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF

cat > data/grafana/dashboards/anx-asset-node-runtime.json <<'EOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 0 },
      "id": 1,
      "targets": [
        {
          "expr": "anx_assets_total",
          "legendFormat": "assets",
          "refId": "A"
        }
      ],
      "title": "Assets total",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "gridPos": { "h": 6, "w": 6, "x": 6, "y": 0 },
      "id": 2,
      "targets": [
        {
          "expr": "anx_metrics_buffer_size",
          "legendFormat": "buffer",
          "refId": "A"
        }
      ],
      "title": "Metrics buffer size",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "gridPos": { "h": 6, "w": 6, "x": 12, "y": 0 },
      "id": 3,
      "targets": [
        {
          "expr": "anx_metrics_storage_flush_errors_total",
          "legendFormat": "flush errors",
          "refId": "A"
        }
      ],
      "title": "Flush errors",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": { "unit": "bytes" }, "overrides": [] },
      "gridPos": { "h": 6, "w": 6, "x": 18, "y": 0 },
      "id": 4,
      "targets": [
        {
          "expr": "anx_metrics_memory_bytes",
          "legendFormat": "memory",
          "refId": "A"
        }
      ],
      "title": "Metrics memory",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 6 },
      "id": 5,
      "targets": [
        {
          "expr": "anx_metrics_storage_writes_total",
          "legendFormat": "writes",
          "refId": "A"
        },
        {
          "expr": "anx_metrics_storage_flushes_total",
          "legendFormat": "flushes",
          "refId": "B"
        }
      ],
      "title": "Storage writes / flushes",
      "type": "timeseries"
    }
  ],
  "schemaVersion": 39,
  "tags": ["anx", "asset-node"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timezone": "browser",
  "title": "ANX asset-node runtime",
  "uid": "anx-asset-node-runtime",
  "version": 1
}
EOF

cat > data/grafana/dashboards/anx-victoriametrics.json <<'EOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "id": null,
  "links": [],
  "panels": [
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "gridPos": { "h": 6, "w": 8, "x": 0, "y": 0 },
      "id": 1,
      "targets": [
        {
          "expr": "up{job=\"victoriametrics\"}",
          "legendFormat": "VM up",
          "refId": "A"
        }
      ],
      "title": "VictoriaMetrics up",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "gridPos": { "h": 6, "w": 8, "x": 8, "y": 0 },
      "id": 2,
      "targets": [
        {
          "expr": "up{job=\"anx-assets-node\"}",
          "legendFormat": "node up",
          "refId": "A"
        }
      ],
      "title": "anx-assets-node scrape up",
      "type": "stat"
    },
    {
      "datasource": { "type": "prometheus", "uid": "" },
      "fieldConfig": { "defaults": {}, "overrides": [] },
      "gridPos": { "h": 6, "w": 8, "x": 16, "y": 0 },
      "id": 3,
      "targets": [
        {
          "expr": "up{job=\"node-exporter\"}",
          "legendFormat": "host",
          "refId": "A"
        }
      ],
      "title": "Node exporter up",
      "type": "stat"
    }
  ],
  "schemaVersion": 39,
  "tags": ["anx", "victoriametrics"],
  "time": { "from": "now-1h", "to": "now" },
  "timezone": "browser",
  "title": "ANX VictoriaMetrics / scrape health",
  "uid": "anx-vm-health",
  "version": 1
}
EOF

echo "==> Init readiness probes"
USB_ROOT="${ANX_USB_ASSET_INIT_ROOT:-/media/usb}"
echo "  USB watch root (host): ${USB_ROOT}"
if [[ -d "$USB_ROOT" ]]; then
  echo "    OK — directory exists (place anx-asset-init-<assetId>/ or .zip at the root)"
else
  echo "    WARN — directory missing; compose create_host_path will create an empty bind. Mount a real USB stick for USB provisioning."
fi

if [[ -e /sys/class/bluetooth/hci0 ]]; then
  echo "  BLE hci0: present"
else
  echo "  BLE hci0: absent — ANX app discovery over Bluetooth will not work; use USB or manual import"
fi

if systemctl is-active --quiet bluetooth 2>/dev/null || pgrep -x bluetoothd >/dev/null 2>&1; then
  echo "  bluetoothd: running (host must stay up for container D-Bus BLE)"
else
  echo "  bluetoothd: not detected — start host bluetoothd before BLE provisioning"
fi

REG="data/config/region-registration.yaml"
if [[ -f "$REG" ]]; then
  echo "  Manual/config: region-registration.yaml present"
else
  echo "  Manual/config: awaiting region-registration.yaml (drop file, USB stick, BLE app, or ./import-asset.sh <portal.zip>)"
fi

echo ""
echo "Next:"
if [[ "$WITH_INFERENCE" == true ]]; then
  echo "  docker compose -f docker-compose.yml -f docker-compose.inference.yml up -d"
  echo "  Edge AI ready — enable edge_ai on the blueprint, pair the asset, then Force Sync."
  echo "  Production tip: COMPOSE_PROFILES=registry-db,inference (omit observe/logs)."
else
  echo "  docker compose up -d"
  echo "  # Manual ZIP:  ./import-asset.sh /path/to/portal-setup.zip && docker compose up -d"
  echo "  # USB:         start stack, then put anx-asset-init-<id> on USB at ${USB_ROOT}"
  echo "  # BLE:         start stack with bluetoothd + hci0; pair ANX-NEW in the ANX app"
  echo "  # Edge AI:     ./prepare.sh --with-inference && docker compose -f docker-compose.yml -f docker-compose.inference.yml up -d"
fi
echo "Done."
