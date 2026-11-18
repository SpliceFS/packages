#!/bin/sh
# Installs the Debian package of the program PROGRAM on the machine this runs on and proves the
# service there. The containers of scripts/service-test.sh run the real service manager, but they
# share the kernel of their host and start from a bare image; a CI runner is a whole machine that
# booted the normal way, with its own firewall, users and running services, so this is the
# closest a check gets to a real install. It checks what the other service test checks, with
# the same functions (scripts/service-check-lib.sh): installing only installs, the documented
# start command enables and starts the service, it runs as its own user, does its job, restarts,
# and removing the package stops and disables it. The reboot is left out: a machine of CI cannot
# be rebooted in the middle of a job. Because it changes the machine, it refuses to run anywhere
# but in CI, and it removes the package again at the end, also when a check fails. Environment:
# PROGRAM; the version comes from dist/PROGRAM/version, which make packages wrote, and a VERSION
# given must be that one. It needs sudo, systemd and curl, and the package in dist/PROGRAM.
#
# What differs between a container and this machine lives in scripts/service-test-host-deb.sh.
# What program.conf, the service check and that file set is unknown to ShellCheck.
# shellcheck disable=SC2154
set -eu

# Before anything is read or run, so that no other mistake can come first.
[ "${CI:-}" = true ] || {
    echo "FAIL: this installs the package on the machine it runs on; it only runs in CI" >&2
    exit 1
}

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
[ -d /run/systemd/system ] || fail "this machine does not run systemd"
# shellcheck source=/dev/null
. "$defs/service-check.sh"
# shellcheck source=service-check-lib.sh
. scripts/service-check-lib.sh
# shellcheck source=service-test-host-deb.sh
. scripts/service-test-host-deb.sh

# The checks take the name of the system they look at; this machine is the only one. It installs
# the deb package, and the shared checks name the format (service-check-lib.sh).
machine=host
format=deb

finish() {
    status=$?
    if [ "$status" -ne 0 ]; then service_report "$machine"; fi
    purge_package
    exit "$status"
}
trap finish EXIT

install_package "$machine"
check_idle_after_install "$machine"
check_documented_start "$machine"
check_user "$machine"
check_answers "$machine"
check_restart "$machine"
check_removal "$machine"

# PRETTY_NAME comes from /etc/os-release, which ShellCheck cannot read here.
# shellcheck source=/dev/null
. /etc/os-release
arch="$(uname -m)"
echo "service test passed on this machine ($PRETTY_NAME, $arch): $name"
