#!/bin/sh
# Runs the setup script, and then the commands it prints, on every system in tests/systems,
# each in its own throwaway container, and keeps going after a failure so one run shows every
# broken system (make e2e).
# Runs on the host. SOURCE says where the setup script and the packages come from
# (scripts/published-site-lib.sh):
# - built (the default) needs the packages from tests/prepare.sh. A local web server stands in
#   for the published site; containers reach it as host.docker.internal. The server takes any
#   free port the system gives it, so no other program and no earlier run can hold it, and the
#   site is built once that port is known.
# - published runs the published setup script against the published site, with its real keys
#   and its published packages, and builds nothing.
# Environment: SOURCE, PLATFORM (linux/amd64 or linux/arm64, empty means this machine's own
# CPU type), ONLY (one format or image).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/fetch-lib.sh
. "$root/scripts/fetch-lib.sh"
# shellcheck source=scripts/published-site-lib.sh
. "$root/scripts/published-site-lib.sh"
check_install_source
parts=$root/dist/e2e
if [ "$install_source" = built ]; then
  for d in keys server client; do
    [ -d "$parts/$d" ] || { echo "no packages: run make e2e-prepare first" >&2; exit 1; }
  done
fi
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform=${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}

# Everything of this run lives here, so runs cannot disturb each other. It is below dist
# because Docker only shares some folders of the host with its containers.
mkdir -p "$parts"
work=$(mktemp -d "$parts/run.XXXXXX")
site=$work/site
. "$root/scripts/site-server-lib.sh"
cleanup() {
  stop_site_server
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Puts the site the containers read in $site and sets site_host, the name the package managers
# print for it.
prepare_built_site() {
  # The site is built after the port is known, and the server finds its files only per request,
  # so it starts before the site folder exists.
  start_site_server "$site" "$work"
  # The address of the site is part of the setup script and its checksum, so the site is built
  # now, with the port the server got.
  if ! KEYS_DIR=$parts/keys BASE_URL="http://host.docker.internal:$site_port" SITE_DIR=$site \
    sh "$root/scripts/build-site.sh" >"$work/build.log" 2>&1; then
    cat "$work/build.log" >&2
    exit 1
  fi
  cp -R "$parts/server" "$parts/client" "$site/"
  site_host=host.docker.internal
}

prepare_published_site() {
  fetch_published_site "$site" "$root"
  site_host=${published_url#*://}
}

case "$install_source" in
  built) prepare_built_site ;;
  *) prepare_published_site ;;
esac
echo "setup script and packages: $install_source ($site_host)"

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
