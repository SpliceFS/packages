#!/bin/sh
# check: freebsd-job.sh: the install and remove messages and the upgrade under a running service are checked for both programs, the other service checks for the client only
# Host test of which checks the FreeBSD job (scripts/freebsd-job.sh) runs for each program: no machine,
# no pkg. The calls of the job's main flow and the lines that decide which of them run are taken out of
# the job and run with the real check-lib.sh of each program, and every check is a stand-in that prints
# its name, so the output is the list of checks the job would run, in order. The package test proves the
# server's service in full, so it needs no more of the job than the checks the package test does not make.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
job="$root/scripts/freebsd-job.sh"

# $1 what is tested, $2 the text wanted, $3 the text got.
same() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

# The lines of the job that say which service checks run, and the calls of the checks.
sed -n '/^service_checks=no$/,/^}$/p' "$job" > "$work/gate.sh"
grep -E '^(service_step )?(check|start)_[a-z_]+$' "$job" > "$work/calls.sh" || :
[ -s "$work/gate.sh" ] || { echo "FAIL: $job has no service_checks gate" >&2; exit 1; }
[ -s "$work/calls.sh" ] || { echo "FAIL: $job calls no check" >&2; exit 1; }

# $1 the program. Prints the checks the job runs for it, one to a line. The check-lib.sh of the program
# is part of the script, as the machine reads it, and expected_user is what it sets or leaves unset.
checks_run_for() {
    {
        printf 'set -eu\n'
        cat "$root/programs/$1/freebsd/check-lib.sh"
        cat "$work/gate.sh"
        sed 's/^service_step //' "$work/calls.sh" | while read -r each; do
            printf '%s() { echo %s; }\n' "$each" "$each"
        done
        cat "$work/calls.sh"
    } > "$work/run-$1.sh"
    sh "$work/run-$1.sh"
}

got="$(checks_run_for server)"
same "the server runs the install message, the start, the upgrade under a running service and the remove message" \
    "check_install_message
start_service
check_upgrade_under_running_service
check_remove_message" "$got"
got="$(checks_run_for client)"
same "the client runs those and the other service checks too, in order" \
    "check_service_idle_after_install
check_install_message
start_service
check_service_running
check_upgrade_under_running_service
check_service_after_removal
check_remove_message" "$got"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "freebsd-job checks: as expected for both programs"
