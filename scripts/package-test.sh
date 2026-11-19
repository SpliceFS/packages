#!/bin/sh
# check-not-run: needs Docker and the packages in dist/PROGRAM (make package-test, make repo-test)
# Tests on every system in packaging/test-systems, all at the same time, each in its own throwaway
# container that is booted as a server (its service manager is process 1), and keeps going after
# a failure so one run shows every system that is broken. Runs on the host (make package-test,
# make repo-test, CI). Usage: package-test.sh [package|repo].
# "package" (the default) install-tests the packages of the program in dist/PROGRAM with
# scripts/package-test-<format>.sh; "repo" tests the signed repository in dist/PROGRAM/repo with
# scripts/repo-test-<format>.sh, which sees the repository at /repo and only the PUBLIC keys at
# /keys. Environment: PROGRAM; the version comes from dist/PROGRAM/version, which make packages
# wrote (scripts/package-record.sh), and a VERSION given must be that one; PLATFORM (linux/amd64
# or linux/arm64) tests that CPU type by emulation, empty means this machine's own; ONLY limits
# the run to one format or image.
set -eu

kind="${1:-package}"
case "$kind" in
    package | repo) ;;
    *) echo "usage: package-test.sh [package|repo]" >&2; exit 2 ;;
esac

: "${PROGRAM:?PROGRAM is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
mounts="-v $root/dist/$PROGRAM:/out"
if [ "$kind" = repo ]; then
    mounts="-v $root/dist/$PROGRAM/repo:/repo:ro -v $root/dist/keys/splicefs.asc:/keys/splicefs.asc:ro"
    mounts="$mounts -v $root/dist/keys/splicefs.rsa.pub:/keys/splicefs.rsa.pub:ro"
fi
systems="$(cat "$root/packaging/test-systems")"
. scripts/systems-lib.sh
work="$(mktemp -d)"
# Every container of this run carries the process id of this run in its name, so the cleanup finds
# all of them and no other run's.
prefix="splicefs-$kind-test-$$"
cleanup() {
    stop_systems
    docker ps -aq --filter "name=$prefix-" | xargs docker rm -f >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# One system, in a container and a log of its own: number $3 of the list.
# Usage: test_system FORMAT IMAGE NUMBER.
test_system() {
    container="$prefix-$3"
    log="$work/$3.log"
    result=1
    # The test runs in the booted system, so the install happens on a server that is up. The
    # container keeps the mounts and the working directory it was started with.
    # $mounts is split on purpose: it holds several -v options. Each step runs only when the
    # one before it worked; the conditions are tests whose status is the answer.
    # shellcheck disable=SC2086,SC2310
    if boot_system --name "$container" --platform "$platform" \
        -e PROGRAM -e VERSION -e PACKAGE_DATE -e REVISION -v "$root":/src:ro $mounts -w /src "$2" >"$log" 2>&1 &&
        wait_booted "$1" "$container" >>"$log" 2>&1 &&
        docker exec "$container" sh "scripts/$kind-test-$1.sh" /out >>"$log" 2>&1; then
        echo "ok   $1 $2"
        result=0
    else
        echo "FAIL $1 $2"
        tail -n 15 "$log" | sed 's/^/     /'
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$result"
}

# The systems to test. A here-document keeps the list in this shell; a pipe would run the loop in
# a subshell.
selected=""
while read -r format image; do
    # Blank lines and comments are skipped; every other line is a system to test.
    case "$format" in "" | "#"*) continue ;; *) ;; esac
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
    # A format without a script for this kind is not a failure; whoever adds
    # scripts/<kind>-test-<format>.sh starts it here.
    if [ ! -f "$root/scripts/$kind-test-$format.sh" ]; then
        echo "skip $format $image (no $kind test yet)"
        continue
    fi
    selected="$selected$format $image
"
done <<LIST
$systems
LIST

run_systems "$work" pull_system test_system <<LIST
$selected
LIST
