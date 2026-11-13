#!/bin/sh
# Runs the setup script, and then the commands it prints, on every system in tests/systems,
# each in its own throwaway container, and keeps going after a failure so one run shows every
# broken system (make e2e).
# Runs on the host and needs the site from tests/prepare.sh. A local web server stands in for
# the published site; containers reach it as host.docker.internal. Environment: PLATFORM
# (linux/amd64 or linux/arm64, empty means this machine's own CPU type), ONLY (one format or
# image), E2E_PORT (must match the one used by prepare.sh).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
port=${E2E_PORT:-18080}
site=$root/dist/e2e/site
[ -f "$site/setup.sh" ] || { echo "no site: run make e2e-prepare first" >&2; exit 1; }
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform=${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}

log=$(mktemp)
http_log=$(mktemp)
server_pid=
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  rm -f "$log" "$http_log"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 -m http.server "$port" --bind 0.0.0.0 --directory "$site" >"$http_log" 2>&1 &
server_pid=$!
up=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/')" \
    >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 0.5
done
[ "$up" -eq 1 ] || { echo "web server did not start on port $port" >&2; cat "$http_log" >&2; exit 1; }

passed=0
failed=0
systems=$(cat "$root/tests/systems")

# A here-document keeps the counters in this shell; a pipe would run the loop in a subshell.
while read -r format image; do
  # Every other line is a system to test.
  case "$format" in "" | "#"*) continue ;; *) ;; esac
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$format" ] && [ "$ONLY" != "$image" ]; then
    continue
  fi
  if docker run --rm --platform "$platform" --add-host=host.docker.internal:host-gateway \
    -v "$site":/site:ro -v "$root/tests":/tests:ro \
    "$image" sh /tests/in-container.sh "$format" >"$log" 2>&1; then
    echo "ok   $format $image"
    passed=$((passed + 1))
  else
    echo "FAIL $format $image"
    tail -n 25 "$log" | sed 's/^/     /'
    failed=$((failed + 1))
  fi
done <<LIST
$systems
LIST

echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
