#!/bin/sh
# Builds the site the end to end test serves (make e2e-prepare). Runs on the host. Both
# sibling repositories are built with ONE set of throwaway keys, so a single install script
# can trust the server and the client packages. Result: dist/e2e/site, laid out like the
# published site. Variables: SERVER_DIR and CLIENT_DIR (default ../server and ../client, since
# CI checks them out elsewhere), E2E_PORT (default 18080, part of the base URL).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
SERVER_DIR=${SERVER_DIR:-$root/../server}
CLIENT_DIR=${CLIENT_DIR:-$root/../client}
port=${E2E_PORT:-18080}

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

# One install script trusts one key pair, so both repositories must carry the same public keys.
for k in splicefs.asc splicefs.rsa.pub; do
  cmp -s "$SERVER_DIR/dist/keys/$k" "$CLIENT_DIR/dist/keys/$k" || {
    echo "FAIL: server and client were signed with different $k" >&2
    exit 1
  }
done

site=$root/dist/e2e/site
rm -rf "$site"
mkdir -p "$site"
(cd "$root" && KEYS_DIR=$keys BASE_URL="http://host.docker.internal:$port" SITE_DIR=$site \
  sh scripts/build-site.sh)
cp -R "$SERVER_DIR/dist/repo" "$site/server"
cp -R "$CLIENT_DIR/dist/repo" "$site/client"
echo "e2e site ready in dist/e2e/site"
