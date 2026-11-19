#!/bin/sh
# Builds what the end to end test serves (make e2e-prepare). Runs on the host. Each program is
# compiled by its own repository (make build-all, in that repository's Linux container), and
# everything after that is done here, with the targets CI uses (make packages, make repo), so
# the packages are the ones CI builds. Both programs are signed with ONE set of throwaway keys
# (make keys), so a single setup script can trust the server and the client packages. Result:
# dist/e2e/keys, dist/e2e/server and dist/e2e/client. The site itself is put together by
# tests/run.sh for every run, because its base URL holds the port of the web server, and the
# system picks that port when the server starts. Variables: SERVER_DIR and CLIENT_DIR (default
# ../server and ../client, since CI checks them out elsewhere).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
SERVER_DIR=${SERVER_DIR:-$root/../server}
CLIENT_DIR=${CLIENT_DIR:-$root/../client}

for d in "$SERVER_DIR" "$CLIENT_DIR"; do
  [ -f "$d/Makefile" ] || { echo "FAIL: $d is not a checkout of the program repository" >&2; exit 1; }
done
SERVER_DIR=$(cd "$SERVER_DIR" && pwd)
CLIENT_DIR=$(cd "$CLIENT_DIR" && pwd)

# Start from nothing, so that no package or key from an earlier run is mixed in.
out=$root/dist/e2e
rm -rf "$out" "$root/dist/keys" "$root/dist/server" "$root/dist/client"

# $1 the program, $2 the folder of its repository. The version is the one the release bot
# writes to VERSION, as build-packages.yml reads it.
package_program() {
  read -r number < "$2/VERSION"
  rm -rf "$2/dist/bin"
  (cd "$2" && make build-all)
  make -C "$root" packages PROGRAM="$1" BIN="$2/dist/bin" SRC="$2" VERSION="v$number"
  make -C "$root" repo PROGRAM="$1"
}

package_program server "$SERVER_DIR"
package_program client "$CLIENT_DIR"

mkdir -p "$out/keys"
cp "$root/dist/keys/splicefs.asc" "$root/dist/keys/splicefs.rsa.pub" "$out/keys/"
cp -R "$root/dist/server/repo" "$out/server"
cp -R "$root/dist/client/repo" "$out/client"
echo "e2e packages ready in dist/e2e"
