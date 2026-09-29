# ANX asset-node IPC (Linux)

GitHub-ready Docker Compose example for running **one** [anx-assets-node](https://github.com/assetsnexus) instance on a Linux industrial PC or Raspberry Pi, next to OEM hardware or a custom control app (Node-RED, etc.).

**Topology: one asset per IPC.** For 3+ assets of different blueprint types, clone this directory (or run the same steps) on each machine. Several `anx-assets-node` processes on one host are unsupported here (USB watcher takes the first init folder; BLE can only advertise one `ANX-NEW` per adapter).

Windows is untested.

## Quick start

```bash
cd anx-public-examples/asset-node-ipc-docker
./prepare.sh
docker compose up -d
```

**Full Edge AI** (asset node + Mongo/Redis + on-device `anx-inference` sidecar):

```bash
./prepare.sh --with-inference
docker compose -f docker-compose.yml -f docker-compose.inference.yml up -d
```

Then register the asset with **one** of the four init paths below.

Pulls `eu1.dockerreg.sdk.assetsnexus.org/anx.asset.node:latest` (multi-arch amd64/arm64). Do **not** set `DOCKER_DEFAULT_PLATFORM` unless you are cross-deploying — forcing `linux/amd64` on a Pi causes `exec format error`.

Edge AI also pulls `eu1.dockerreg.sdk.assetsnexus.org/anx-inference-backend:latest`. A later publish step must produce that image with `ANX_INFERENCE_MODE=asset_edge` support (Mongo+Redis edge storage profile). Until then, compose validates but the container will not run agents.

## Which containers are required vs optional

| Service | Profile | Production? | Notes |
|---------|---------|-------------|--------|
| `anx-assets-node` | *(always)* | **Required** | The asset runtime |
| VictoriaMetrics | *(always)* | **Required** | Local metrics buffer / flush target for the node |
| Postgres, MongoDB, Redis | `registry-db` | Optional | Safe to omit on small boxes today (node does not require live DB clients at startup). Keep when you want the same data stores as a full portal ZIP, or to share Mongo/Redis with a future inference sidecar |
| Mosquitto (MQTT) | `oem` | Optional | Broker for OEM / plant integrations |
| Node-RED | `oem` | Optional | Prototype / site business logic as a **consumer** of the asset API — not required by the node |
| Grafana | `observe` | **Dev only** | Local dashboards. Production assets use Nexus APIs and **portal** dashboards |
| Prometheus + node-exporter | `observe` | **Dev only** | Scrapes the node `/metrics` endpoint for local Grafana. Not needed in production (same: portal / Nexus) |
| Loki | `logs` | **Dev only** | Local log aggregation. Not required on production assets |
| `anx-inference` | `inference` | Optional (Edge AI) | On-device asset_edge sidecar. Needs `registry-db`. Start via `./prepare.sh --with-inference` |

**Production tip:** run with `COMPOSE_PROFILES=registry-db` (or empty) — omit `observe` and `logs`. Add `oem` only if you need MQTT and/or Node-RED on the box. For Edge AI without lab dashboards: `COMPOSE_PROFILES=registry-db,inference`.

Default in `.env.example` includes `observe` for a convenient lab/dev box:

```bash
COMPOSE_PROFILES=registry-db,observe
```

Minimal / production-lean:

```bash
# in .env
COMPOSE_PROFILES=registry-db
# or COMPOSE_PROFILES= for node + VictoriaMetrics only
./prepare.sh
docker compose up -d
```

`prepare.sh` writes `data/config/database.yaml` with `enabled: true` only for profiles that will run.

## Four init options

After `docker compose up -d`, the node logs `awaiting provisioning` until it has a `region-registration.yaml` with an asset (or registry) id.

### 1. Manual compose / portal ZIP

1. In the ANX portal, create a prototype and download the **manual compose** (or generic) setup ZIP.
2. On the IPC:

   ```bash
   ./prepare.sh
   ./import-asset.sh /path/to/portal-setup.zip
   docker compose up -d
   ```

`import-asset.sh` copies config/certs into `./data`, merges non-secret `.env` keys (e.g. `SINGLE_ASSET_DIR`), and may write `docker-compose.override.yml` for host network / device binds. It **refuses** a second different asset id on the same IPC and **refuses** an unrecognisable ZIP.

### 2. USB

1. Start the stack (`./prepare.sh && docker compose up -d`) so the USB watcher is active.
2. From the portal, download the **USB** registration package for this prototype.
3. Copy `anx-asset-init-<assetId>/` **or** `anx-asset-init-<assetId>.zip` to the **root** of a USB stick mounted at `ANX_USB_ASSET_INIT_ROOT` (default `/media/usb`).
4. Wait for `registration_result.json` (folder) or `*.registration_result.json` (beside the zip) with success, then confirm **online** in the portal.

`prepare.sh` prints whether the USB path exists.

### 3. Bluetooth (ANX app)

1. Host must run `bluetoothd`; adapter at `/sys/class/bluetooth/hci0`. Compose mounts `/run/dbus` and `/dev/rfkill`.
2. `./prepare.sh` reports BLE readiness.
3. `docker compose up -d` — node advertises **`ANX-NEW`** until registered, then **`ANX-<code>`**.
4. Pair and provision from the ANX mobile app (blueprint must allow BLE / `bleApp`).

If BLE hardware or D-Bus is missing, the node keeps USB, manual, and pairing-link paths working.

### 4. Pairing link (one-time URL + token)

Use when the stack is already up (`./prepare.sh && docker compose up -d`) and you can reach the region over the network (no USB stick / no BLE).

1. In the portal setup wizard → **Pairing link**. Choose **primary** or **secondary** (forced **primary** if this is the first edge node for the asset). Default expiry **2 hours** (max **48 hours**). Create the link and copy the token (shown once) plus one redeem URL.
2. On the IPC, redeem against the **local** asset-node command port (`SERVER_PORT`, default **28480**). Pick **one** registry redeem URL per curl (wizard lists assets-registry HTTPS origins — not region hosts — do not spam health checks; re-run with another listed URL only if the first fails):

```bash
curl -sS -X POST http://127.0.0.1:28480/command/anx.asset.pairing.redeem \
  -H 'content-type: application/json' \
  -d '{"payload":{"url":"https://REGISTRY_URL/api/public/asset-pairing/redeem","token":"TOKEN","role":"primary"}}'
```

Replace `REGISTRY_URL` with a registry origin from the wizard (full path ends with `/api/public/asset-pairing/redeem`); replace `TOKEN` with the one-time secret. Do **not** paste a region public URL. Use `"role":"secondary"` only when pairing an HA replica after a primary already exists.

The node pulls the **full init bundle** (same writer as USB/BLE: `region-registration.yaml`, `general.yml`, `certs/region-ca.crt`) then the normal registration loop runs. The token is sent to the region (Authorization header), not used as a local admin password. Links are **one-time**; expired or reused tokens are rejected.

## GitHub edge example: nexus-asset-example-docker-dev

Public mirror: [assetsnexus/nexus-asset-example-docker-dev](https://github.com/assetsnexus/nexus-asset-example-docker-dev).  
In this workspace the same tree is `anx-public-examples/asset-node-ipc-docker` (same `prepare.sh` / `import-asset.sh` / compose layout).

Copy-paste start as an edge node:

```bash
git clone https://github.com/assetsnexus/nexus-asset-example-docker-dev.git
cd nexus-asset-example-docker-dev
./prepare.sh          # generates certs/secrets under data/ (and profiles)
docker compose up -d
```

`prepare.sh` is the init shell script that writes local secrets and readiness checks (including whether the USB path / BLE adapter exist). Then pair with **one** of the four options above.

**Pairing-link example** (after portal create; substitute real values):

```bash
# REGISTRY_URL: one of the assets-registry redeem URLs from the portal (not a region host)
# TOKEN: one-time secret shown once at link creation
curl -sS -X POST http://127.0.0.1:28480/command/anx.asset.pairing.redeem \
  -H 'content-type: application/json' \
  -d '{"payload":{"url":"https://REGISTRY_URL/api/public/asset-pairing/redeem","token":"TOKEN","role":"primary"}}'
```

If that URL fails, re-run the same curl with another registry alternative listed in the portal (do not invent URLs or use region public URLs). Role `primary` is required for the first edge node; use `secondary` only for an additional replica.

## Region and registry endpoints

Pairing writes `data/config/region-registration.yaml`. Day to day you do not type a region URL. The portal ZIP, the USB init folder, and Bluetooth provisioning all carry the same list.

**Edge (this IPC, one asset).** `regionNode.endpoints` is every public origin of the region: the node’s `publicEndpoints` plus `publicUrl` and `alternativeUrls`. `assetsRegistry.endpoints` is every registry `publicEndpoints` entry plus every **enabled** `endpointConfigs` URL (intranet and online). A dev box that must point at an intranet registry and an online region at the same time is the exception: edit those two lists in `data/config/region-registration.yaml` after import. Leave them alone after a normal pair.

**Registry mode** (this process registers as an assets registry, `regionNode.assetsRegistryId` set, `assetsRegistry.enabled` false). Set `regionNode.endpoints` to the region origins to register into. Example and default seed:

```yaml
regionNode:
  assetsRegistryId: <registry-integration-id>
  endpointProbeIntervalSec: 300
  endpoints:
    - host: 1.west.eu.region.sandbox.assetsnexus.org
      port: 443
      tls: true
      mode: rest
```

`https://1.west.eu.region.sandbox.assetsnexus.org` is the sandbox seed. Add further origins as more list entries.

The node picks the lowest-latency origin that answers `GET /health`. While that origin stays up, it probes the full list **once every 5 minutes** (`endpointProbeIntervalSec`, default 300). Heartbeats (60s) go only to the winner and do not fan out. If the winner fails, it probes immediately and fails over. A URL that appears only inside a health response is used when its certificate chains to `caCert` (`../certs/region-ca.crt` from the pairing bundle). Health JSON cannot send the node to an arbitrary host.

## After pairing: blueprint sync from the registry

Pairing / init only boots identity and region (or assets-registry) connectivity. Once the asset is registered and online it **pulls its blueprint configuration and other relevant instance data** from the region / assets registry on the normal heartbeat / config-sync path (`clonedConfigs`, endpoints, jobs, offerings, etc.). You do not hand-maintain a full config tree on the IPC for day-to-day operation — the digital twin on Nexus is the source of truth; Force Sync in the portal can push an immediate pull.

## Recovering a destroyed or replaced device

Restoring a wiped IPC or swapping hardware follows the same idea as first-time init (manual ZIP, USB, or BLE), then the twin takes over:

1. **Bring the stack up** on the replacement host (`./prepare.sh` → `docker compose up -d`) and **re-pair** with the existing asset identity (same four init options, using registration material for that prototype / instance).
2. **Quick availability** — after registration the node restores operational config from its **digital twin** (region / registry): blueprint-derived configs and other twin-held state sync down so the asset can come online again without waiting on bulk history.
3. **Background restore** — metrics, recordings, and other bulk history are then restored in the background from **contracted blob / backup storage** (blueprint deployment Restic / storage rules and operator contracts), not from stuffing large archives into the pairing package.

Until identity is re-established the node stays in `awaiting provisioning`. After pairing, watch portal status (online) and sync; bulk backup replay continues asynchronously.

## Dev observability (`observe` + `logs`) — not for production

Grafana, Prometheus, node-exporter, and Loki are **development / lab aids** so you can inspect the node on the IPC without the portal. Production fleets rely on **Nexus APIs and portal dashboards** instead — leave these profiles off.

When `observe` is enabled, `prepare.sh` provisions:

- **ANX asset-node runtime** — gauges from `http://anx-assets-node:8081/metrics`
- **ANX VictoriaMetrics / scrape health** — `up` for VM, node, node-exporter

UI: `http://<ipc>:${GRAFANA_PORT:-3001}` (admin password from `.env` after `prepare.sh`).

## On-device Edge AI (anx-inference sidecar)

When the blueprint has **`edge_ai.runtime.enabled`** (or a synonym that enables that flag), the asset node expects a local `anx-inference` sidecar on the IPC.

### One-command full setup

```bash
./prepare.sh --with-inference
docker compose -f docker-compose.yml -f docker-compose.inference.yml up -d
```

`prepare.sh --with-inference` (also when `COMPOSE_PROFILES` already contains `inference`):

1. Ensures `.env.inference` from the example.
2. Sets `COMPOSE_PROFILES` to include `registry-db` and `inference`.
3. Writes a local trust token to `./data/edge/local-trust.token` (gitignored) and points both the asset node and inference at it.
4. Writes `ANX_INFERENCE_MODE=asset_edge`, Mongo/Redis URLs for the compose siblings, and `ANX_ASSETS_NODE_URL=http://anx-assets-node:28480`.
5. Prints: "Edge AI ready — enable edge_ai on the blueprint, pair the asset, then Force Sync."

After pairing: **Force Sync** → portal Asset → Edge AI page should show `runtime: detected` and agents applied once the published image supports `asset_edge`.

**Images (publish step, not done in this example):**

| Image | Tag | Notes |
|-------|-----|--------|
| `eu1.dockerreg.sdk.assetsnexus.org/anx.asset.node` | `latest` | Must understand `ANX_EDGE_INFERENCE_URL` + local trust file |
| `eu1.dockerreg.sdk.assetsnexus.org/anx-inference-backend` | `latest` | Must understand `ANX_INFERENCE_MODE=asset_edge` (Mongo+Redis only) |

Host camera/mic for `live_interface` labs: copy `docker-compose.override.inference.example.yml` → `docker-compose.override.yml` (gitignored).

### Acceptance (Edge AI)

| Setup | Pass |
|-------|------|
| `./prepare.sh --with-inference` + blueprint `edge_ai.runtime.enabled` + Force Sync | Heartbeat `edgeAi.state=ok` (or `runtime: detected`) within a few minutes of Force Sync once images are published |

### Troubleshooting (Edge AI)

| Symptom | Likely cause |
|---------|----------------|
| Inference up but `runtime: missing` | `ANX_EDGE_INFERENCE_URL` / token file mismatch between node and inference |
| Inference exits on start | Mongo/Redis not in profiles — rerun `./prepare.sh --with-inference` |
| `exec format error` on inference | Wrong arch image; same fix as asset node (multi-arch / unset `DOCKER_DEFAULT_PLATFORM`) |
| Placeholder / mode ignored | Published `anx-inference-backend:latest` does not yet include `asset_edge` — wait for the publish step |

## OEM / Node-RED (`oem`)

Enable profile `oem` for **Mosquitto** and **Node-RED** when you want prototype or site business logic next to the asset (flows calling REST/gRPC/WebSocket). Both are optional consumers — the asset node runs without them. You can also point a custom OEM app at `SERVER_PORT` / `GRPC_PORT` / `WEBSOCKET_PORT` without Node-RED.

Profile `oem-io` starts Mosquitto and a separate Node-RED service (`nodered-io`, host port 1881) with `flows/port-io.json`. The flow subscribes to `anx/<assetId>/port/<portId>/{active,error}` and publishes `relay_state` plus green and red LED topics. The broker is TLS on `mqtt:8883`. Set the `ipc-mqtt` node user to `anx` and the password from `prepare.sh` in the Node-RED editor — the flow file does not store credentials. The CA is mounted at `/certs/ca.crt`. Unit 10 of the Modbus slave reads `data/protocol_mappings/pm-anx-port-io-v1.json`.

## Acceptance runbook (init paths)

Use different blueprints (e.g. plain full asset, BLE runtime enabled, serial/OEM custom container). Create one prototype instance each. Use **one IPC (or checkout) per asset**.

| IPC | Init | Steps | Pass criteria |
|-----|------|-------|----------------|
| A | Manual | `./prepare.sh` → `./import-asset.sh <prototype.zip>` → `docker compose up -d` | Portal shows registered → online; Force Sync applies |
| B | USB | `./prepare.sh` → `up -d` (logs awaiting) → put USB init folder on stick | `registration_result.json` success; portal online |
| C | BLE | `./prepare.sh` (hci0 + bluetoothd OK) → `up -d` → ANX app pairs `ANX-NEW` | Advertised name becomes `ANX-<code>`; portal online |
| D | Pairing link | `./prepare.sh` → `up -d` → portal create link → local `anx.asset.pairing.redeem` curl | Portal online; `data/certs/region-ca.crt` present |

On each IPC: portal shows online. With `observe` (dev only): Grafana shows node gauges and VictoriaMetrics scrape up.

## Robot acceptance (two blueprints)

| IPC | Blueprint | Control | Pass |
|-----|-----------|---------|------|
| Robot A | `1773445812320-wer87qrc1` | Node creates a uinput Xbox pad; Python reads it via evdev; telemetry returns on MQTT | `evtest` shows the virtual pad; health dashboard shows `robot.*` metrics; Flask `/video_feed` plays |
| Robot B | RaspTank MQTT (`rasptank-mqtt`) | No `/dev/uinput`. Controller state and commands go over MQTT | Same metrics and camera without a gamepad device |
| Fallback | Either with `ANX_CONTROL_SOURCE=auto` | Unplug USB | Service logs switch to MQTT within 5s and drive still stops on deadman |

Enable `ANX_BRIDGE_ENABLED=true` on the robot service and the compose `oem` profile (Mosquitto password from `prepare.sh`).

Physical phone/USB stick may not be available in CI — confirm with node logs (`awaiting provisioning` / `USB provisioning complete` / `BLE GATT peripheral started`) and the result files above.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `exec format error` | Image is wrong arch; rebuild multi-arch or unset `DOCKER_DEFAULT_PLATFORM` |
| BLE never appears | No `hci0`, or host `bluetoothd` down, or D-Bus not mounted |
| USB ignored | Stick not under `ANX_USB_ASSET_INIT_ROOT`; folder not named `anx-asset-init-*` |
| Pairing redeem 401/409 | Token expired (default 2h / max 48h), already used, or wrong Authorization value |
| Pairing redeem HTTP fail | Wrong region URL — retry with another alternative URL from the portal list (one attempt per URL) |
| Grafana empty | Profile `observe` off, or scrape still pointing at `:9090` — regenerate ZIP / re-run `prepare.sh` |

## Files

| Path | Role |
|------|------|
| `docker-compose.yml` | Main stack + profiles |
| `docker-compose.inference.yml` | Edge AI `anx-inference` sidecar (`asset_edge`) |
| `docker-compose.override.inference.example.yml` | Optional host camera/mic binds |
| `prepare.sh` | Secrets, database.yaml, Grafana/Prometheus, `--with-inference` |
| `import-asset.sh` | Apply portal ZIP without clobbering secrets |
| `.env.example` | Documented defaults (no secrets) |
| `.env.inference.example` | Edge sidecar env template |
| `flows/port-io.json` | Node-RED port-io flow (`oem-io`) |
| `data/protocol_mappings/` | OEM protocol mapping JSON |
| `data/` | Bind-mounted `LOCAL_DATA_PATH` (config, certs, edge trust, grafana) |
| `volumes/` | Bind-mounted persistent data for DBs / Grafana / MQTT / etc. (gitignored content) |
