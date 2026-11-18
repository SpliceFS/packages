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

# The machine booted before the job started, so there is nothing to wait for: the check after a
# removal asks only that its service manager is healthy. A machine with systemd that is still
# starting or is stopping is not.
wait_booted() {
    state="$(systemctl is-system-running 2>/dev/null)" || true
    case "$state" in running | degraded) return 0 ;; *) return 1 ;; esac
}
