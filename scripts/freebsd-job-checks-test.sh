#!/bin/sh
# check: freebsd-job.sh: the service checks run for a program that has a check-lib.sh (the client) and for no other (the server)
# Host test of which checks the FreeBSD job (scripts/freebsd-job.sh) runs for each program: no machine,
# no pkg. The calls of the job's main flow and the lines that decide which of them run are taken out of
# the job and run in an input folder that holds the real check-lib.sh of each program that has one, and
# every check is a stand-in that prints its name, so the output is the list of checks the job would run,
# in order. The package test proves the server's service, its upgrade under a running service and its
# messages, so the server has no check-lib.sh and the job makes no service check for it.
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

# The lines of the job that source the check-lib.sh of the input folder, when there is one, and say
# which service checks run; and the calls of the checks.
sed -n '/^service_checks=no$/,/^}$/p' "$job" > "$work/gate.sh"
grep -E '^(service_step )?(check|start)_[a-z_]+$' "$job" > "$work/calls.sh" || :
[ -s "$work/gate.sh" ] || { echo "FAIL: $job has no service_checks gate" >&2; exit 1; }
[ -s "$work/calls.sh" ] || { echo "FAIL: $job calls no check" >&2; exit 1; }

# $1 the program. Prints the checks the job runs for it, one to a line. The input folder holds the
# check-lib.sh of the program when the program has one, as the host puts it there for the machine.
checks_run_for() {
    in_folder="$work/in-$1"
    mkdir -p "$in_folder"
    if [ -f "$root/programs/$1/freebsd/check-lib.sh" ]; then
        cp "$root/programs/$1/freebsd/check-lib.sh" "$in_folder/check-lib.sh"
    fi
    {
        printf 'set -eu\nin=%s\n' "$in_folder"
        cat "$work/gate.sh"
        sed 's/^service_step //' "$work/calls.sh" | while read -r each; do
            printf '%s() { echo %s; }\n' "$each" "$each"
        done
        cat "$work/calls.sh"
    } > "$work/run-$1.sh"
    sh "$work/run-$1.sh"
}

# The server's checks are the package test's, so nothing of the server is in the job's input folder.
[ ! -e "$root/programs/server/freebsd/check-lib.sh" ] || {
    printf 'FAIL the server has a check-lib.sh, so the job would run service checks for it\n'
    failed=$((failed + 1))
}
got="$(checks_run_for server)"
same "the server runs no service check" "" "$got"
got="$(checks_run_for client)"
same "the client runs every service check, in order" \
    "check_service_idle_after_install
check_install_message
start_service
check_service_running
check_upgrade_under_running_service
check_service_after_removal
check_remove_message" "$got"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "freebsd-job checks: as expected for both programs"
