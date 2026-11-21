#!/bin/sh
# check: service-upgrade-lib.sh: after an upgrade over a running service, deb, rpm and apk restart it and pkg leaves the old process running; a same-version reinstall on pkg prints the install message
# Test of check_upgrade_of_running_service of scripts/service-upgrade-lib.sh. The service functions it
# asks are stand-ins that read the process id and the version of the running service from files of the
# test, and a restart writes the files of the case: so each case says what the upgrade did and what a
# restart does, and the check must tell a package that keeps its promise from one that does not.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
# The version of the new package, which a case may set to the installed one (v1.0.0) for a same-version reinstall.
new_version=v1.1.0

# $1 case name, $2 the format, $3 the process id and $4 the version the service has after the upgrade
# (before it is 100 and v1.0.0), $5 the process id and $6 the version it has after a restart, $7 what
# the check must say: ok, or the text of its refusal (which ends the run with a failing status).
upgrade_runs() {
    case_dir="$work/$1"
    mkdir -p "$case_dir"
    echo 100 >"$case_dir/running-pid.server"
    echo v1.0.0 >"$case_dir/running-version.server"
    echo "$3" >"$case_dir/pid"
    echo "$4" >"$case_dir/version"
    # The script is for the shell that env starts, which reads its own variables.
    # shellcheck disable=SC2016
    got="$(env FORMAT="$2" PROGRAM=server VERSION="$new_version" own="$case_dir" after_pid="$5" after_version="$6" \
        sh -c '
        fail() { echo "FAIL: $*"; exit 1; }
        must() { message="$1"; shift; "$@" || fail "$message"; }
        wait_for() { shift; "$@"; }
        active_and_answering() { true; }
        service_pid() { cat "$own/pid"; }
        reported_version() { cat "$own/version"; }
        service_restart() { echo "$after_pid" >"$own/pid"; echo "$after_version" >"$own/version"; echo "restart" >>"$own/calls"; }
        . scripts/service-upgrade-lib.sh
        format="$FORMAT"
        check_upgrade_of_running_service system' 2>&1)" && status=ok || status=refused
    case "$status:$got" in
        ok:*"ok: "*"$7"* | refused:*"FAIL: "*"$7"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted "%s" got %s: "%s"\n' "$1" "$7" "$status" "$got"
            failed=$((failed + 1))
            ;;
    esac
}

# The packages that restart a running service on upgrade (deb, rpm, apk): a new process that reports the new version.
for format in deb rpm apk; do
    upgrade_runs "$format: a restart by the package passes" "$format" 200 v1.1.0 0 "" "restarted the service"
    upgrade_runs "$format: a service that kept its process is found" "$format" 100 v1.0.0 0 "" "the upgrade did not start a new process of the service"
    upgrade_runs "$format: a new process that reports the old version is found" "$format" 200 v1.0.0 0 "" "after the upgrade the service reports v1.0.0, not the new v1.1.0"
done
upgrade_runs "deb: the restart the package does is not left to the test" deb 200 v1.1.0 0 "" "restarted the service"
if [ -f "$work/deb: the restart the package does is not left to the test/calls" ]; then
    echo "FAIL the test ran a restart itself for a package that restarts the service"
    failed=$((failed + 1))
else
    echo "ok   no restart is run by the test for a package that restarts the service"
fi

# A reinstall of the same version is not an upgrade. deb and rpm run their scripts on it, so they restart the
# service as for an upgrade; apk and pkg do not (pkg add -f installs the files again and ends no process), so the
# same process keeps running, as the same version.
new_version=v1.0.0
for format in deb rpm; do
    upgrade_runs "$format, same version: a restart by the package passes" "$format" 200 v1.0.0 0 "" "restarted the service"
    upgrade_runs "$format, same version: a service that kept its process is found" "$format" 100 v1.0.0 0 "" "the upgrade did not start a new process of the service"
done
for format in apk pkg; do
    upgrade_runs "$format, same version: the process that keeps running passes" "$format" 100 v1.0.0 0 "" "kept running"
    upgrade_runs "$format, same version: a restart nobody asked for is found" "$format" 200 v1.0.0 0 "" "a reinstall of the same version on $format restarted the service"
    upgrade_runs "$format, same version: a service that reports another version is found" "$format" 100 v1.1.0 0 "" "after a reinstall of the same version on $format the service reports v1.1.0, not v1.0.0"
done
if [ -f "$work/pkg, same version: the process that keeps running passes/calls" ]; then
    echo "FAIL the test ran a restart itself after a reinstall of the same version on pkg"
    failed=$((failed + 1))
else
    echo "ok   no restart is run by the test after a reinstall of the same version on pkg"
fi
new_version=v1.1.0

# pkg: the old process keeps running and reports the old version, until the command of the upgrade
# message restarts it.
upgrade_runs "pkg: the old process kept, then the restart runs the new version" pkg 100 v1.0.0 300 v1.1.0 "as v1.1.0"
upgrade_runs "pkg: a service the package restarted is found" pkg 200 v1.1.0 300 v1.1.0 "the upgrade, before its restart, restarted the service, which it does not do"
upgrade_runs "pkg: a service that reports the new version before its restart is found" pkg 100 v1.1.0 300 v1.1.0 "after the upgrade, before its restart, the service reports v1.1.0, not v1.0.0"
upgrade_runs "pkg: a restart that still runs the old version is found" pkg 100 v1.0.0 300 v1.0.0 "after the restart the service reports v1.0.0, not the new v1.1.0"
upgrade_runs "pkg: a restart that keeps the process is found" pkg 100 v1.0.0 100 v1.1.0 "the restart did not start a new process of the service"
if [ -f "$work/pkg: the old process kept, then the restart runs the new version/calls" ]; then
    echo "ok   pkg: the restart of the upgrade message ran"
else
    echo "FAIL pkg: the restart of the upgrade message did not run"
    failed=$((failed + 1))
fi

# The message pkg prints when the new package is put over the installed one: pkg add -f of the same version
# is a forced install, which prints the install message, not the upgrade message. $1 the format, $2 the
# installed version, $3 the new one, $4 the message type.
message_is() {
    # The script is for the shell that env starts, which reads its own variables.
    # shellcheck disable=SC2016
    got="$(env FORMAT="$1" sh -c 'format="$FORMAT"; . scripts/service-upgrade-lib.sh; put_over_message "$1" "$2"' sh "$2" "$3")"
    if [ "$got" = "$4" ]; then
        printf 'ok   %s %s over %s prints the %s message\n' "$1" "$3" "$2" "$4"
    else
        printf 'FAIL %s %s over %s: wanted the %s message, got "%s"\n' "$1" "$3" "$2" "$4" "$got"
        failed=$((failed + 1))
    fi
}
message_is pkg v1.0.0 v1.1.0 upgrade
message_is pkg v1.0.0 v1.0.0 install
message_is deb v1.0.0 v1.0.0 upgrade
message_is apk v1.0.0 v1.1.0 upgrade

if [ "$failed" -ne 0 ]; then
    echo "$failed service-upgrade-lib case(s) failed"
    exit 1
fi
echo "service-upgrade-lib: all cases as expected"
