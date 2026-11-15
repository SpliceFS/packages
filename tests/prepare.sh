#!/bin/sh
# Builds what the end to end test serves (make e2e-prepare). Runs on the host. Both sibling
# repositories are built with ONE set of throwaway keys, so a single setup script can trust
# the server and the client packages. Result: dist/e2e/keys, dist/e2e/server and
# dist/e2e/client. The site itself is put together by tests/run.sh for every run, because its
# base URL holds the port of the web server, and the system picks that port when the server
# starts. Variables: SERVER_DIR and CLIENT_DIR (default ../server and ../client, since CI
# checks them out elsewhere).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
SERVER_DIR=${SERVER_DIR:-$root/../server}
CLIENT_DIR=${CLIENT_DIR:-$root/../client}

for d in "$SERVER_DIR" "$CLIENT_DIR"; do
  [ -f "$d/Makefile" ] || { echo "FAIL: $d is not a checkout of the sibling repository" >&2; exit 1; }
done
SERVER_DIR=$(cd "$SERVER_DIR" && pwd)
CLIENT_DIR=$(cd "$CLIENT_DIR" && pwd)

# make clean first so no package or key from an earlier run is mixed in.
(cd "$SERVER_DIR" && make clean && make package && make repo)
keys=$SERVER_DIR/dist/keys
# The client signs with the server's keys; only the folder, never a key's content, is passed.
(cd "$CLIENT_DIR" && make clean && SIGNING_DIR=$keys make package repo)

# One setup script trusts one key pair, so both repositories must carry the same public keys.
for k in splicefs.asc splicefs.rsa.pub; do
  cmp -s "$SERVER_DIR/dist/keys/$k" "$CLIENT_DIR/dist/keys/$k" || {
    echo "FAIL: server and client were signed with different $k" >&2
    exit 1
  }
done

out=$root/dist/e2e
rm -rf "$out"
mkdir -p "$out/keys"
cp "$keys/splicefs.asc" "$keys/splicefs.rsa.pub" "$out/keys/"
cp -R "$SERVER_DIR/dist/repo" "$out/server"
cp -R "$CLIENT_DIR/dist/repo" "$out/client"
echo "e2e packages ready in dist/e2e"
