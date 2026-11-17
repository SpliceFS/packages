#!/bin/sh
# Installs the rpm package for this CPU type, checks what the package promises, then
# removes it and checks what is left. It runs inside a throwaway container of any rpm based
# system (make package-test): Rocky Linux, Amazon Linux, openSUSE.
set -eu

dir="${1:?usage: package-test-rpm.sh PACKAGE_DIR}"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
# shellcheck source=package-test-lib.sh
. scripts/package-test-lib.sh
unit="/usr/lib/systemd/system/$program.service"
rpm="$dir/$name-$rpmver-1.$(uname -m).rpm"
[ -f "$rpm" ] || fail "$rpm does not exist; run make packages first"

# rpm alone cannot fetch dependencies; the system's package manager does when one is
# missing. The build key is a throwaway, so zypper must be told to accept an unsigned file.
install_missing() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "$1" >/dev/null
    else
        zypper --non-interactive install --allow-unsigned-rpm "$1" >/dev/null
    fi
}
if ! rpm -i "$rpm" >/dev/null 2>&1; then
    install_missing "$rpm"
fi
rpm -q "$name" >/dev/null || fail "package is not installed"

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

rpm -U --replacepkgs "$rpm" >/dev/null || fail "installing over itself failed"

touch "$kept"
rpm -e "$name" >/dev/null 2>&1 || fail "remove failed"
check_programs_removed
[ -f "$kept" ] || fail "remove must keep the configuration"

# shellcheck source=/dev/null
. /etc/os-release
# PRETTY_NAME comes from /etc/os-release.
# shellcheck disable=SC2154
echo "package test passed on $PRETTY_NAME: $(basename "$rpm")"
