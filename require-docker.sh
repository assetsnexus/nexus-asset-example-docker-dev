#!/usr/bin/env bash
# Resolve the docker client once and require the Compose plugin.
# Sourced by prepare.sh, up.sh, and down.sh. Does not install Docker.

require_docker() {
  if [[ "${_ANX_DOCKER_READY:-}" == 1 ]]; then
    return 0
  fi

  local candidate=""
  local path=""
  if candidate="$(command -v docker 2>/dev/null)" && [[ -n "$candidate" && -x "$candidate" ]]; then
    :
  else
    candidate=""
    for path in /usr/bin/docker /usr/local/bin/docker; do
      if [[ -x "$path" ]]; then
        candidate="$path"
        break
      fi
    done
  fi

  if [[ -z "$candidate" ]]; then
    echo "ERROR: docker was not found." >&2
    echo "Install Docker Engine and the Docker Compose plugin, and ensure docker is on PATH." >&2
    echo "Also checked /usr/bin/docker and /usr/local/bin/docker." >&2
    exit 1
  fi

  if ! "$candidate" compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose plugin was not found (docker compose failed)." >&2
    echo "Install Docker Engine and the Docker Compose plugin, and ensure docker is on PATH." >&2
    echo "Also checked /usr/bin/docker and /usr/local/bin/docker." >&2
    exit 1
  fi

  DOCKER="$candidate"
  _ANX_DOCKER_READY=1
}
