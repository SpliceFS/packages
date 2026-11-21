#!/bin/sh
# check: service-upgrade-lib.sh: after an upgrade over a running service, deb, rpm and apk restart it and pkg leaves the old process running
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
    got="$(env FORMAT="$2" PROGRAM=server VERSION=v1.1.0 own="$case_dir" after_pid="$5" after_version="$6" \
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

# pkg: the old process keeps running and reports the old version, until the command of the upgrade
# message restarts it.
upgrade_runs "pkg: the old process kept, then the restart runs the new version" pkg 100 v1.0.0 300 v1.1.0 "as v1.1.0"
upgrade_runs "pkg: a service the package restarted is found" pkg 200 v1.1.0 300 v1.1.0 "the upgrade restarted the service, which a pkg package does not do"
upgrade_runs "pkg: a service that reports the new version before its restart is found" pkg 100 v1.1.0 300 v1.1.0 "before the restart the service reports v1.1.0, not the old v1.0.0"
upgrade_runs "pkg: a restart that still runs the old version is found" pkg 100 v1.0.0 300 v1.0.0 "after the restart the service reports v1.0.0, not the new v1.1.0"
upgrade_runs "pkg: a restart that keeps the process is found" pkg 100 v1.0.0 100 v1.1.0 "the restart did not start a new process of the service"
if [ -f "$work/pkg: the old process kept, then the restart runs the new version/calls" ]; then
    echo "ok   pkg: the restart of the upgrade message ran"
else
    echo "FAIL pkg: the restart of the upgrade message did not run"
    failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
    echo "$failed service-upgrade-lib case(s) failed"
    exit 1
fi
echo "service-upgrade-lib: all cases as expected"
