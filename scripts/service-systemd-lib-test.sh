#!/bin/sh
# Test of scripts/service-systemd-lib.sh, which part of make check runs on any computer: each
# function asks the systemd of a system the same question in a container and on the machine
# itself, and which of them need root. The two functions that run a command on a system are
# stand-ins that write down what they are asked to run, so nothing is started.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
program=splicefs-test

# The stand-ins write the way they ran the command and the system, then the command. The one
# that asks systemd for the process id answers with FAKE_PID.
on_system() {
    target="$1"
    shift
    echo "user $target $*" >> "$work/calls"
    case "$*" in "systemctl show"*) printf '%s\n' "$FAKE_PID" ;; *) ;; esac
}
on_system_as_root() {
    target="$1"
    shift
    echo "root $target $*" >> "$work/calls"
}
# shellcheck source=service-systemd-lib.sh
. scripts/service-systemd-lib.sh

# $1 what is checked, $2 the calls it made, one a line, as written down; then the function and
# its arguments.
check_calls() {
    case_name="$1"
    want="$2"
    shift 2
    : > "$work/calls"
    "$@" > /dev/null 2>&1 || true
    got="$(cat "$work/calls")"
    if [ "$got" = "$want" ]; then printf 'ok   %s\n' "$case_name"; else
        printf 'FAIL %s\nwant:\n%s\ngot:\n%s\n' "$case_name" "$want" "$got"
        failed=$((failed + 1))
    fi
}

FAKE_PID=4242
u=splicefs-test.service
check_calls "the unit is the program's own" "user box systemctl is-active --quiet $u" service_active box
check_calls "enabled is asked as a user" "user box systemctl is-enabled --quiet $u" service_enabled box
check_calls "the documented start command runs as root" "root box systemctl enable --now $u" service_start_enable box
check_calls "stop runs as root" "root box systemctl stop $u" service_stop box
check_calls "restart runs as root" "root box systemctl restart $u" service_restart box
check_calls "the process id is asked as a user" "user box systemctl show -p MainPID --value $u" service_pid box
check_calls "the report holds the status and the log, the log as root" \
    "user box systemctl status --no-pager --full $u
root box journalctl -u $u --no-pager -n 30" service_report box

# The owner is read where the process is, with the process id as the argument of the script.
# The first call asks for the process id; the script of the second is on several lines. The status
# of service_user is not the answer here, so set -e being off inside it changes nothing.
: > "$work/calls"
# shellcheck disable=SC2310
service_user box > /dev/null 2>&1 || true
last="$(tail -n +2 "$work/calls")"
case "$last" in
    "user box sh -c "*" sh 4242") printf 'ok   the owner is read from the process on the system\n' ;;
    *)
        printf 'FAIL the owner is read from the process on the system: got\n%s\n' "$last"
        failed=$((failed + 1))
        ;;
esac

# A service that does not run has no process, and then there is no owner to look up.
FAKE_PID=0
# The status is the answer here, so set -e being off inside the function changes nothing.
: > "$work/calls"
# shellcheck disable=SC2310
if service_user box > /dev/null 2>&1; then
    printf 'FAIL no process, no owner: succeeded\n'
    failed=$((failed + 1))
else
    printf 'ok   no process, no owner\n'
fi

[ "$failed" -eq 0 ]
