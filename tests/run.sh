#!/bin/sh
# Runs the setup script, and then the commands it prints, on every system in tests/systems,
# each in its own throwaway container, and keeps going after a failure so one run shows every
# broken system (make e2e).
# Runs on the host, against the published site: its published setup script, its real keys and
# its published packages (scripts/published-site-lib.sh). Nothing is built.
# Environment: PLATFORM (linux/amd64 or linux/arm64, empty means this machine's own
# CPU type), ONLY (one format or image).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/fetch-lib.sh
. "$root/scripts/fetch-lib.sh"
# shellcheck source=scripts/published-site-lib.sh
. "$root/scripts/published-site-lib.sh"
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform=${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}

# Everything of this run lives here, so runs cannot disturb each other. It is below dist
# because Docker only shares some folders of the host with its containers.
parts=$root/dist/e2e
mkdir -p "$parts"
work=$(mktemp -d "$parts/run.XXXXXX")
site=$work/site
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fetch_published_site "$site" "$root"
site_host=${published_url#*://}
echo "setup script and packages: published ($site_host)"

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
  if docker run --rm --platform "$platform" \
    -v "$site":/site:ro -v "$root/tests":/tests:ro \
    "$image" sh /tests/in-container.sh "$format" "$site_host" >"$work/container.log" 2>&1; then
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
