#!/usr/bin/env bash
# Stop the edge stack. Host data under ./data and ./volumes is kept.
# -v / --volumes is ignored so Docker cannot remove volumes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--volumes|--volumes=*)
      echo "Ignoring $1 — down.sh does not delete volumes or bind-mounted data." >&2
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  source .env
  set +a
fi
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.inference.yml}"

if [[ ${#args[@]} -gt 0 ]]; then
  docker compose down "${args[@]}"
else
  docker compose down
fi

echo "Stopped. ./data and ./volumes were not removed."
