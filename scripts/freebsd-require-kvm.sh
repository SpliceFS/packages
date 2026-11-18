#!/bin/sh
# Stops at once, and says why, on a computer that cannot give a FreeBSD machine hardware
# virtualization. make package-freebsd and make e2e-freebsd run it before they build
# anything, so that nobody waits for a build to learn that the machine cannot start.
set -eu

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

. scripts/freebsd-lib.sh
freebsd_require_kvm
