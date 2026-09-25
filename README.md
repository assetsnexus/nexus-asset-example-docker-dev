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

Then register the asset with **one** of the three init paths below.

Pulls `eu1.dockerreg.sdk.assetsnexus.org/anx-assets-node:latest` (multi-arch amd64/arm64). Do **not** set `DOCKER_DEFAULT_PLATFORM` unless you are cross-deploying — forcing `linux/amd64` on a Pi causes `exec format error`.

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

**Production tip:** run with `COMPOSE_PROFILES=registry-db` (or empty) — omit `observe` and `logs`. Add `oem` only if you need MQTT and/or Node-RED on the box.

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

## Three init options

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

If BLE hardware or D-Bus is missing, the node keeps USB and manual paths working.

## After pairing: blueprint sync from the registry

Pairing / init only boots identity and region (or assets-registry) connectivity. Once the asset is registered and online it **pulls its blueprint configuration and other relevant instance data** from the region / assets registry on the normal heartbeat / config-sync path (`clonedConfigs`, endpoints, jobs, offerings, etc.). You do not hand-maintain a full config tree on the IPC for day-to-day operation — the digital twin on Nexus is the source of truth; Force Sync in the portal can push an immediate pull.

## Recovering a destroyed or replaced device

Restoring a wiped IPC or swapping hardware follows the same idea as first-time init (manual ZIP, USB, or BLE), then the twin takes over:

1. **Bring the stack up** on the replacement host (`./prepare.sh` → `docker compose up -d`) and **re-pair** with the existing asset identity (same three init options, using registration material for that prototype / instance).
2. **Quick availability** — after registration the node restores operational config from its **digital twin** (region / registry): blueprint-derived configs and other twin-held state sync down so the asset can come online again without waiting on bulk history.
3. **Background restore** — metrics, recordings, and other bulk history are then restored in the background from **contracted blob / backup storage** (blueprint deployment Restic / storage rules and operator contracts), not from stuffing large archives into the pairing package.

Until identity is re-established the node stays in `awaiting provisioning`. After pairing, watch portal status (online) and sync; bulk backup replay continues asynchronously.

## Dev observability (`observe` + `logs`) — not for production

Grafana, Prometheus, node-exporter, and Loki are **development / lab aids** so you can inspect the node on the IPC without the portal. Production fleets rely on **Nexus APIs and portal dashboards** instead — leave these profiles off.

When `observe` is enabled, `prepare.sh` provisions:

- **ANX asset-node runtime** — gauges from `http://anx-assets-node:8081/metrics`
- **ANX VictoriaMetrics / scrape health** — `up` for VM, node, node-exporter

UI: `http://<ipc>:${GRAFANA_PORT:-3001}` (admin password from `.env` after `prepare.sh`).

## Optional on-device inference (not wired)

If the blueprint **Deployment → Local agents** toggle is enabled, an `anx-inference` sidecar is *expected* on the IPC. Start the placeholder:

```bash
cp .env.inference.example .env.inference   # if missing
docker compose -f docker-compose.yml -f docker-compose.inference.yml --profile inference up -d
```

This does **not** run agents, models, or a region bridge yet — replace the image/command when on-device inference is implemented. When wired, it can reuse the asset stack’s MongoDB/Redis (`registry-db`); it does not need Grafana/Prometheus/Loki.

## OEM / Node-RED (`oem`)

Enable profile `oem` for **Mosquitto** and **Node-RED** when you want prototype or site business logic next to the asset (flows calling REST/gRPC/WebSocket). Both are optional consumers — the asset node runs without them. You can also point a custom OEM app at `SERVER_PORT` / `GRPC_PORT` / `WEBSOCKET_PORT` without Node-RED.

## Acceptance runbook (3 assets, 3 types, 3 init paths)

Use three different blueprints (e.g. plain full asset, BLE runtime enabled, serial/OEM custom container). Create one prototype instance each. Use **one IPC (or checkout) per asset**.

| IPC | Init | Steps | Pass criteria |
|-----|------|-------|----------------|
| A | Manual | `./prepare.sh` → `./import-asset.sh <prototype.zip>` → `docker compose up -d` | Portal shows registered → online; Force Sync applies |
| B | USB | `./prepare.sh` → `up -d` (logs awaiting) → put USB init folder on stick | `registration_result.json` success; portal online |
| C | BLE | `./prepare.sh` (hci0 + bluetoothd OK) → `up -d` → ANX app pairs `ANX-NEW` | Advertised name becomes `ANX-<code>`; portal online |

On each IPC: portal shows online. With `observe` (dev only): Grafana shows node gauges and VictoriaMetrics scrape up.

Physical phone/USB stick may not be available in CI — confirm with node logs (`awaiting provisioning` / `USB provisioning complete` / `BLE GATT peripheral started`) and the result files above.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `exec format error` | Image is wrong arch; rebuild multi-arch or unset `DOCKER_DEFAULT_PLATFORM` |
| BLE never appears | No `hci0`, or host `bluetoothd` down, or D-Bus not mounted |
| USB ignored | Stick not under `ANX_USB_ASSET_INIT_ROOT`; folder not named `anx-asset-init-*` |
| Grafana empty | Profile `observe` off, or scrape still pointing at `:9090` — regenerate ZIP / re-run `prepare.sh` |

## Files

| Path | Role |
|------|------|
| `docker-compose.yml` | Main stack + profiles |
| `docker-compose.inference.yml` | Optional inference placeholder |
| `prepare.sh` | Secrets, database.yaml, Grafana/Prometheus, readiness probes |
| `import-asset.sh` | Apply portal ZIP without clobbering secrets |
| `.env.example` | Documented defaults |
| `data/` | Bind-mounted `LOCAL_DATA_PATH` (config, certs, grafana provisioning) |
| `volumes/` | Bind-mounted persistent data for DBs / Grafana / MQTT / etc. (gitignored content) |
