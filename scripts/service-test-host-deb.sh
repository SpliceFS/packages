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

# What the checks ask of the machine's service manager is that the package left nothing behind:
# no job of the program's unit is still pending and no unit failed that had not failed before the
# install. The rest of the machine is not ours to judge: a runner may still be booting, or stay
# "starting" for minutes, and have units of its own that fail, so is-system-running says nothing
# about the package.

# The units that are failed now, one per line.
failed_units() {
    listing="$(systemctl list-units --state=failed --plain --no-legend)" || return 1
    printf '%s\n' "$listing" | awk 'NF { print $1 }'
}

# Run before the install: the units that failed then are not the package's doing.
record_failed_units() {
    failed_before="$(failed_units)" || fail "the failed units of the machine cannot be listed"
}

# The units that failed since record_failed_units, one per line.
new_failed_units() {
    now="$(failed_units)" || return 1
    [ -n "$now" ] || return 0
    printf '%s\n' "$now" | while read -r failed_unit; do
        printf '%s\n' "$failed_before" | grep -q -x -F -e "$failed_unit" || echo "$failed_unit"
    done
}

# The pending jobs of the program's unit, one per line; the unit is the second column.
pending_jobs() {
    listing="$(systemctl list-jobs --plain --no-legend)" || return 1
    printf '%s\n' "$listing" | awk -v unit="$unit" '$2 == unit'
}

# Sets $unsettled to what is still wrong, and succeeds when nothing is.
host_settled() {
    if ! pending="$(pending_jobs)" || ! failures="$(new_failed_units)"; then
        unsettled="systemctl cannot list the jobs and the failed units"
        return 1
    fi
    unsettled="${pending:+a job of $unit is pending: $pending. }${failures:+new failed units: $(printf '%s' "$failures" | tr '\n' ' ')}"
    [ -z "$unsettled" ]
}

# Waits for the job and the failures to end (HOST_SETTLE_SECONDS, 60 unless a test sets it), since
# right after a removal systemd is often still busy with the unit, and names what is still wrong.
# The shared check after a removal calls it by this name.
wait_booted() {
    # host_settled is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_for "${HOST_SETTLE_SECONDS:-60}" host_settled && return 0
    echo "the machine did not settle within ${HOST_SETTLE_SECONDS:-60} seconds: $unsettled" >&2
    return 1
}
