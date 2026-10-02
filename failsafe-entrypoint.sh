#!/bin/sh
# Run the node, then apply actuator failsafes from the last hardware_io snapshot.
# sh as PID 1 ignores SIGTERM unless it is trapped, so Docker would SIGKILL
# the container before this script reached the failsafe.
set -u
pid=
cleanup() {
  trap - TERM INT
  if [ -n "${pid}" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" || true
    pid=
  fi
  if [ -x /app/anx-assets-node ]; then
    /app/anx-assets-node failsafe || echo "failsafe after signal failed" >&2
  fi
  exit 0
}
trap cleanup TERM INT
"$@" &
pid=$!
wait "$pid"
code=$?
pid=
trap - TERM INT
if [ -x /app/anx-assets-node ]; then
  /app/anx-assets-node failsafe || echo "failsafe after exit code ${code} failed" >&2
fi
exit "$code"
