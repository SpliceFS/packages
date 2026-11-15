#!/bin/sh
# Runs the setup script, and then the commands it prints, on every system in tests/systems,
# each in its own throwaway container, and keeps going after a failure so one run shows every
# broken system (make e2e).
# Runs on the host and needs the packages from tests/prepare.sh. A local web server stands in
# for the published site; containers reach it as host.docker.internal. The server takes any
# free port the system gives it, so no other program and no earlier run can hold it, and the
# site is built once that port is known. Environment: PLATFORM (linux/amd64 or linux/arm64,
# empty means this machine's own CPU type), ONLY (one format or image).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
parts=$root/dist/e2e
for d in keys server client; do
  [ -d "$parts/$d" ] || { echo "no packages: run make e2e-prepare first" >&2; exit 1; }
done
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform=${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}

# Everything of this run lives here, so runs cannot disturb each other. It is below dist
# because Docker only shares some folders of the host with its containers.
work=$(mktemp -d "$parts/run.XXXXXX")
site=$work/site
server_pid=
timer_pid=
cleanup() {
  [ -z "$timer_pid" ] || kill "$timer_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  # The server is waited for, so its port is closed and it is gone when this script ends.
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Kills the process $1 after a minute. It is a safety stop only: nothing waits for this time
# to pass, the start below waits for the line the server prints. TERM ends it early and takes
# its sleep along.
safety_stop() {
  trap 'kill $!; exit 0' TERM
  sleep 60 &
  wait $!
  kill "$1"
}

# The server prints one line on stdout once its socket is bound, and the port is in that line.
# A pipe carries it, so the read below returns when the line is there, or at end of file when
# the server died first. Nothing else goes to stdout, so no one has to drain the pipe. The
# site is built after the port is known, and the server finds its files only per request, so
# it can start before the site folder exists.
mkfifo "$work/banner"
python3 -u -m http.server 0 --bind 0.0.0.0 --directory "$site" >"$work/banner" 2>"$work/server.log" &
server_pid=$!
safety_stop "$server_pid" >/dev/null 2>&1 &
timer_pid=$!
exec 3<"$work/banner"
banner=
read -r banner <&3 || true
exec 3<&-
kill "$timer_pid" 2>/dev/null || true
wait "$timer_pid" 2>/dev/null || true
timer_pid=
case "$banner" in
  "Serving HTTP on "*" port "[0-9]*) ;;
  *) echo "web server did not start" >&2; cat "$work/server.log" >&2; exit 1 ;;
esac
port=${banner#* port }
port=${port%% *}

# The address of the site is part of the setup script and its checksum, so the site is built
# now, with the port the server got.
if ! KEYS_DIR=$parts/keys BASE_URL="http://host.docker.internal:$port" SITE_DIR=$site \
  sh "$root/scripts/build-site.sh" >"$work/build.log" 2>&1; then
  cat "$work/build.log" >&2
  exit 1
fi
cp -R "$parts/server" "$parts/client" "$site/"

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
    "$image" sh /tests/in-container.sh "$format" >"$work/container.log" 2>&1; then
    echo "ok   $format $image"
    passed=$((passed + 1))
  else
    echo "FAIL $format $image"
    tail -n 25 "$work/container.log" | sed 's/^/     /'
    failed=$((failed + 1))
  fi
done <<LIST
$systems
LIST

echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
