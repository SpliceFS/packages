#!/bin/sh
# Installs the Debian package for this CPU type, checks what the package promises, then
# removes and purges it and checks what is left. It runs inside a throwaway Debian or
# Ubuntu container (make package-test).
set -eu

dir="${1:?usage: package-test-deb.sh PACKAGE_DIR}"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
# shellcheck source=package-test-lib.sh
. scripts/package-test-lib.sh
unit="/usr/lib/systemd/system/$program.service"
deb="$dir/${name}_${debver}_$(dpkg --print-architecture).deb"
[ -f "$deb" ] || fail "$deb does not exist; run make packages first"

# dpkg alone cannot fetch dependencies; apt finishes the install when one is missing.
if ! dpkg -i "$deb" >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq -f >/dev/null
fi
dpkg -s "$name" | grep -q '^Status: install ok installed' || fail "package is not installed"

check_versions
[ -f "$unit" ] || fail "service unit is missing"
if grep -q /usr/local/bin "$unit"; then fail "service unit points at /usr/local/bin"; fi
check_config_folders
check_links
check_extras
kept="$confdir/$(echo "$confsubdirs" | head -n 1)/local.yaml"
user="$(sed -n 's/^User=//p' "$unit")"
if [ -n "$user" ]; then
    getent passwd "$user" >/dev/null || fail "user $user was not created"
fi

dpkg -i "$deb" >/dev/null || fail "installing over itself failed"

touch "$kept"
dpkg -r "$name" >/dev/null 2>&1 || fail "remove failed"
check_programs_removed
[ -f "$kept" ] || fail "remove must keep the configuration"
dpkg -P "$name" >/dev/null 2>&1 || fail "purge failed"
[ ! -e "$confdir" ] || fail "purge must delete the configuration"

# shellcheck source=/dev/null
. /etc/os-release
# PRETTY_NAME comes from /etc/os-release.
# shellcheck disable=SC2154
echo "package test passed on $PRETTY_NAME: $(basename "$deb")"
