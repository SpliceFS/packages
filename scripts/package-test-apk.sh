#!/bin/sh
# Installs the Alpine package for this CPU type, checks what the package promises, then
# removes it and checks what is left. It runs inside a throwaway Alpine container
# (make package-test).
set -eu

dir="${1:?usage: package-test-apk.sh PACKAGE_DIR}"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
# shellcheck source=package-test-lib.sh
. scripts/package-test-lib.sh
init="/etc/init.d/$program"
apk="$dir/alpine/$(apk --print-arch)/$name-$apkver-r$apkrel.apk"
[ -f "$apk" ] || fail "$apk does not exist; run make packages first"

# The build key is a throwaway, so the signature cannot be checked here.
apk add -q --allow-untrusted "$apk" || fail "install failed"
apk info -e "$name" >/dev/null || fail "package is not installed"

check_versions
[ -x "$init" ] || fail "service script is missing or not executable"
check_config_folders
check_links
check_extras
kept="$confdir/$(echo "$confsubdirs" | head -n 1)/local.yaml"
user="$(sed -n 's/^command_user="\([^:"]*\).*/\1/p' "$init")"
if [ -n "$user" ]; then
    grep -q "^$user:" /etc/passwd || fail "user $user was not created"
fi

touch "$kept"
apk del -q "$name" || fail "remove failed"
check_programs_removed
[ -f "$kept" ] || fail "remove must keep the configuration"

# shellcheck source=/dev/null
. /etc/os-release
# PRETTY_NAME comes from /etc/os-release.
# shellcheck disable=SC2154
echo "package test passed on $PRETTY_NAME: $(basename "$apk")"
