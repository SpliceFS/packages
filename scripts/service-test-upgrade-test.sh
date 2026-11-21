#!/bin/sh
# check: service-test-upgrade.sh: the service test puts the package file over the installed one with the system's package manager
# Test of the upgrade_package function of scripts/service-test-deb.sh and scripts/service-test-rpm.sh.
# docker is a stand-in that runs the command it is given here, and the package managers are stand-ins
# on the PATH that write their arguments to a file, so the test needs no Docker and runs in
# milliseconds (part of make check). rpm and dpkg fail when they are called: they ignore the
# settings of the system's package manager, so a package is never put in place through them.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

mkdir "$work/bin" "$work/bin-dnf"
# The stand-ins expand their own variables when they run.
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = exec ] || exit 1\nshift\nwhile [ "$1" = -e ] || [ "$1" = -w ]; do shift 2; done\nshift\nexec "$@"\n' > "$work/bin/docker"
for manager in apt-get zypper; do
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$manager" > "$work/bin/$manager"
done
for program in rpm dpkg; do
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\nexit 1\n' "$program" > "$work/bin/$program"
done
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "dnf $*" >> "$CALLS"\n' > "$work/bin-dnf/dnf"
chmod 755 "$work"/bin/* "$work/bin-dnf/dnf"

# $1 case name, $2 the folder of stand-ins that goes first on the PATH, $3 format, $4 the one line the
# package manager must be called with. The words of scripts/package-lib.sh are given by hand.
upgrade() {
    : > "$work/calls"
    status=0
    CALLS="$work/calls" PATH="$2:$work/bin:/usr/bin:/bin" PROGRAM=server name=splicefs-server \
        debver=1.2.3 rpmver=1.2.3 rpmrel=1 platform=linux/amd64 VERSION=v1.2.3 format="$3" sh -c \
        '. "scripts/service-test-$format.sh"; upgrade_package container' || status=$?
    got="$(cat "$work/calls")"
    if [ "$got" = "$4" ] && [ "$status" -eq 0 ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s", status %s\n' "$1" "$4" "$got" "$status"
        failed=$((failed + 1))
    fi
}

upgrade "deb: the file is reinstalled with apt-get" "$work/bin" deb \
    "apt-get install -y -qq --reinstall /pkg/server/splicefs-server_1.2.3_amd64.deb"
upgrade "rpm with dnf: the file is reinstalled with dnf" "$work/bin-dnf" rpm \
    "dnf reinstall -y -q --nogpgcheck /pkg/server/splicefs-server-1.2.3-1.x86_64.rpm"
upgrade "rpm with zypper: the file is reinstalled with zypper" "$work/bin" rpm \
    "zypper --non-interactive --quiet install --force --allow-unsigned-rpm /pkg/server/splicefs-server-1.2.3-1.x86_64.rpm"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "service test upgrade: all cases as expected"
