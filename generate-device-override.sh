#!/bin/sh
# Write a compose override that mounts only devices the blueprint named.
# Base docker-compose.yml stays on /dev/rfkill. consumer "external" is skipped.
# USB serial is mounted from /dev/serial/by-id, never ttyUSB or ttyACM.
#
#   ./generate-device-override.sh requirements.json [out.yml]
#   SYSFS_GPIO=/sys/class/gpio
set -u
req_file=${1:-}
out_file=${2:-docker-compose.devices.yml}
sysfs=${SYSFS_GPIO:-/sys/class/gpio}
if [ -z "$req_file" ] || [ ! -f "$req_file" ]; then
  echo "usage: $0 requirements.json [out.yml]" >&2
  exit 2
fi

python3 - "$req_file" "$out_file" "$sysfs" <<'PY'
import json, os, sys
req_path, out_path, sysfs = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(req_path))
reqs = doc.get("deviceRequirements") or doc.get("device_requirements") or doc
if isinstance(reqs, dict):
    reqs = reqs.get("deviceRequirements") or []
devices = ["/dev/rfkill:/dev/rfkill"]
volumes = []
for req in reqs:
    if req.get("consumer") not in ("node", "service"):
        continue
    kind = req.get("kind")
    match = req.get("match") or {}
    if kind == "i2c":
        bus = match.get("busName") or "i2c-1"
        devices.append(f"/dev/{bus}:/dev/{bus}")
    elif kind == "spi":
        devices.append("/dev/spidev0.0:/dev/spidev0.0")
        devices.append("/dev/spidev0.1:/dev/spidev0.1")
    elif kind == "video":
        node = match.get("device")
        if node:
            devices.append(f"{node}:{node}")
    elif kind == "usb-serial":
        volumes.append("/dev/serial/by-id:/dev/serial/by-id:ro")
    elif kind == "gpiochip":
        labels = []
        if match.get("chipLabel"):
            labels.append(match["chipLabel"])
        labels.extend(match.get("chipLabels") or [])
        if not os.path.isdir(sysfs):
            continue
        for name in sorted(os.listdir(sysfs)):
            if not name.startswith("gpiochip"):
                continue
            label_path = os.path.join(sysfs, name, "label")
            try:
                label = open(label_path).read().strip()
            except OSError:
                continue
            if label in labels:
                devices.append(f"/dev/{name}:/dev/{name}")
lines = [
    "# Generated from blueprint deviceRequirements. Do not mount unused buses.",
    "services:",
    "  anx-assets-node:",
    "    devices:",
]
for dev in dict.fromkeys(devices):
    lines.append(f"      - {dev}")
if volumes:
    lines.append("    volumes:")
    for vol in dict.fromkeys(volumes):
        lines.append(f"      - {vol}")
open(out_path, "w").write("\n".join(lines) + "\n")
print(out_path)
PY
