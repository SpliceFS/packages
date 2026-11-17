#!/bin/sh
# Proves the service, not only the files: on every system in packaging/test-systems it boots
# one container of the server image (scripts/package-lib.sh, boot_system), whose process 1 is
# that system's own service manager, installs the package of the program PROGRAM from dist/PROGRAM
# into the running system, and checks that the service starts by itself, runs as its own user,
# does its job, restarts, comes back after a reboot and stops when the package is removed. A
# failing system does not stop the run, so one run shows every system that is broken. Runs on the
# host (make service-test, CI); it needs Docker and curl. Environment: PROGRAM; the version comes
# from dist/PROGRAM/version, which make packages wrote (scripts/package-record.sh), and a VERSION
# given must be that one; PLATFORM (linux/amd64 or linux/arm64) tests that CPU type by
# emulation, empty means this machine's own; ONLY limits the run to one format or one image of
# packaging/test-systems.
#
# What differs between package formats lives in scripts/service-test-<format>.sh, which this
# file sources and which defines these functions (the first argument is the container):
#   install_package C        installs the package from /pkg with the native package manager
#   remove_package C         removes it again
#   service_active C         status 0 when the service manager says the service is running
#   service_enabled C        status 0 when the service starts at boot
#   service_restart C        restarts the service through the service manager
#   service_user C           prints the user the main process of the service runs as
#   service_report C         prints the service's status and its last 30 log lines
#   skip_reason IMAGE        prints why this image cannot be tested, or nothing when it can
# expected_user and answers_text are set by the service check of the program, which is chosen at
# run time, so ShellCheck cannot follow it.
# shellcheck disable=SC2154
set -eu

: "${PROGRAM:?PROGRAM is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh

# What "the service works" means differs per program, so it lives with the program's definitions:
# expected_user, run_options (extra docker run options), answers C (status 0 when the
# service does its job) and answers_text (the words for the report). A program that listens on
# a port sets port, which the test opens in the firewall of a system that runs one.
# shellcheck source=/dev/null
. "$defs/service-check.sh"

# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
log="$(mktemp)"
container=""
cleanup() {
    rm -f "$log"
    if [ -n "$container" ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The checks that tell whether the service works (wait_for, must, refuse, check_*).
# shellcheck source=service-check-lib.sh
. scripts/service-check-lib.sh

# One system. Every command is guarded with fail because errexit is off for anything called
# from an if; the caller runs this in a subshell so that fail ends only this system.
run_checks() {
    # The log of the container holds what the service manager said while it booted; without it
    # the cause of a system that does not come up stays hidden.
    # wait_booted is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_booted "$format" "$1" || {
        echo "--- last 30 lines of the container output"
        docker logs --tail 30 "$1" 2>&1 || true
        fail "the service manager did not finish booting"
    }
    install_package "$1" || fail "installing the package failed"
    must "opening the port ${port:-} in the firewall failed" open_firewall "$1"
    check_starts_by_itself "$1"
    check_user "$1"
    check_answers "$1"
    check_restart "$1"
    check_reboot "$1"
    check_removal "$1"
}

passed=0
failed=0
count=0
systems="$(cat packaging/test-systems)"

# A here-document keeps the counters in this shell; a pipe would run the loop in a subshell.
while read -r format image; do
    # Blank lines and comments are skipped; every other line is a system to test.
    case "$format" in "" | "#"*) continue ;; *) ;; esac
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
    if [ ! -f "scripts/service-test-$format.sh" ]; then
        echo "skipped: no service test for $format yet ($image)"
        continue
    fi
    # shellcheck source=/dev/null
    . "scripts/service-test-$format.sh"
    reason="$(skip_reason "$image")"
    if [ -n "$reason" ]; then
        echo "skipped: $format $image: $reason"
        continue
    fi

    # A registry failure must not look like a failed service test.
    # Errexit is off for the call to read its status; pull_image checks every command itself.
    set +e
    pull_image "$platform" "$image"
    pulled=$?
    set -e
    if [ "$pulled" -ne 0 ]; then
        echo "FAIL $format $image"
        echo "     could not download the image $image (3 tries)"
        failed=$((failed + 1))
        continue
    fi

    count=$((count + 1))
    container="splicefs-service-test-$$-$count"
    started=0
    options="$(run_options)"
    # run_options prints whole options and nothing else, so it is left unquoted on purpose.
    # boot_system is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2086,SC2310
    if boot_system --name "$container" --platform "$platform" \
        -v "$root/dist/$PROGRAM":/pkg:ro $options "$image" 2>"$log"; then
        started=1
    fi

    # Errexit is switched off here on purpose: every command of run_checks is guarded with
    # fail, and a failing check must end only this system, not the whole run.
    checked=1
    if [ "$started" -eq 1 ]; then
        set +e
        (run_checks "$container") >>"$log" 2>&1
        checked=$?
        set -e
    fi
    if [ "$checked" -eq 0 ]; then
        echo "ok   $format $image"
        passed=$((passed + 1))
    else
        echo "FAIL $format $image"
        {
            echo "--- $program.service on $image"
            service_report "$container" || true
        } >>"$log" 2>&1
        tail -n 70 "$log" | sed 's/^/     /'
        failed=$((failed + 1))
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    container=""
done <<LIST
$systems
LIST

echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
