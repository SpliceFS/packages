#!/bin/sh
# Debian and Ubuntu (systemd) functions of scripts/service-test-host.sh; the file is sourced, so
# it runs nothing itself. They are the functions scripts/service-test-deb.sh defines for a
# container, with the machine itself as the one system: the first argument of every function is
# the name the checks of scripts/service-check-lib.sh pass on, and is not needed here. The
# service functions are those of scripts/service-systemd-lib.sh. $name, $debver, $program and
# $PROGRAM come from scripts/package-lib.sh.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

# This machine is the only system, so the first argument of the two functions that run a command,
# the name the checks pass on, is dropped. Only what changes the machine needs root.
on_system() {
    shift
    "$@"
}

on_system_as_root() {
    shift
    sudo "$@"
}

# shellcheck source=service-systemd-lib.sh
. scripts/service-systemd-lib.sh

install_package() {
    pkg="dist/$PROGRAM/${name}_${debver}_$(dpkg --print-architecture).deb"
    [ -f "$pkg" ] || fail "$pkg does not exist; run make packages first"
    # apt resolves the dependencies of a local file, which it takes only as a path.
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PWD/$pkg" >/dev/null
}

remove_package() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "$name" >/dev/null
}

# The package must go even when a check fails, or a run on the same machine starts dirty. A
# purge also takes the data the service made.
purge_package() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$name" >/dev/null 2>&1 || true
}

# What the service checks ask of a system, answered by the machine itself.
answers() {
    answers_here
}

# The check after a removal asks that the machine's service manager is healthy: running, or
# degraded (a runner has units of its own that fail). Right after a package is removed, systemd is
# often still "starting" for a moment while it reloads units and finishes jobs, so the check waits
# for the state to settle (HOST_SETTLE_SECONDS, 60 unless a test sets it) instead of looking once,
# and names the state it ends in.
host_settled() {
    state="$(systemctl is-system-running 2>/dev/null)" || true
    case "$state" in running | degraded) return 0 ;; *) return 1 ;; esac
}

wait_booted() {
    # host_settled is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_for "${HOST_SETTLE_SECONDS:-60}" host_settled && return 0
    echo "systemd is still '$state' after ${HOST_SETTLE_SECONDS:-60} seconds" >&2
    return 1
}
