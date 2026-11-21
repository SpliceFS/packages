#!/bin/sh
# check: systems-lib.sh: every system starts at once, output in order, failures named, stopping ends the systems
# Test of run_systems in scripts/systems-lib.sh with stand-in commands instead of containers, so it
# needs no Docker. The stand-ins meet at FIFOs: each says it started and then waits to be released,
# and the test releases them only after every one has started, so a runner that started them one
# after another would never get past the first (the run is wrapped in a time limit in CI).
# No wait in this test depends on a system that could end early: the test reads what the systems
# say from a FIFO whose write end only the systems hold, so the read ends when they are gone, and
# it waits for a system by its process id. It sends no signal: delivering one is the shell's job.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/systems-lib.sh"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
mkfifo "$t/started"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A system to prepare fails when its image is "bad-pull", like an image that cannot be downloaded.
prepare() {
    echo "prepared $2"
    [ "$2" != bad-pull ]
}

# The FIFO the systems say they started on. The test reads it on descriptor 3; the systems write it
# on descriptor 7, which they inherit. The test opens both ends without waiting for the other (the
# write end read-write), starts the systems, and closes its own write end (hand_over_started), so
# the only writers left are the systems and a read of it ends at end of file when they are gone.
open_started() {
    exec 7<>"$t/started"
    exec 3<"$t/started"
}
hand_over_started() { exec 7>&-; }

# Says it started on descriptor 7, waits for its release, prints two lines and passes unless its
# image is "broken". It holds its release FIFO open for reading and writing before it says it
# started, so the test's write of the release always finds a reader.
stand_in() {
    exec 8<>"$t/go.$3"
    echo "$3" >&7
    read -r _ <&8
    echo "ok   $1 $2"
    echo "     second line of $2"
    [ "$2" != broken ]
}

# Waits until N systems said they started, then releases them, the last one first, so they end in
# the opposite order of the list. The read ends with a failure when the systems are gone before
# they all started. Usage: release_all N
release_all() {
    seen=0
    while [ "$seen" -lt "$1" ]; do
        read -r _ <&3 || fail "the run ended before $1 systems started"
        seen=$((seen + 1))
    done
    exec 3<&-
    each="$1"
    while [ "$each" -gt 0 ]; do
        echo go >"$t/go.$each"
        each=$((each - 1))
    done
}

run() {
    rm -rf "$t/out" && mkdir "$t/out"
    for n in 1 2 3; do rm -f "$t/go.$n" && mkfifo "$t/go.$n"; done
    open_started
    run_systems "$t/out" prepare stand_in >"$t/result" 2>&1 <<LIST &
$1
LIST
    runner=$!
    hand_over_started
    release_all "$2"
    status=0
    wait "$runner" || status=$?
}

# All three start before any ends; the outputs come in the order of the list, whole.
run "deb one
rpm two
apk three" 3
result="$(cat "$t/result")"
[ "$status" -eq 0 ] || fail "a run where every system passed failed: $result"
expected="prepared one
ok   deb one
     second line of one
prepared two
ok   rpm two
     second line of two
prepared three
ok   apk three
     second line of three
passed: 3  failed: 0"
[ "$result" = "$expected" ] || fail "the output is not each system in order:
$result"
echo "ok: all systems start before any ends, output in list order"

# One failing test and one failing preparation fail the run, and both are named.
run "deb one
rpm broken
apk bad-pull" 2
[ "$status" -ne 0 ] || fail "a run with a failed system passed"
# Each failed system is named on a line of its own that says what it is, so the name stays with
# its line when a CI log merges standard output and standard error line by line.
expected="passed: 1  failed: 2
failed system: rpm broken
failed system: apk bad-pull"
result="$(cat "$t/result")"
summary="$(tail -n 3 "$t/result")"
[ "$summary" = "$expected" ] || fail "the counts or the failed systems are wrong:
$result"
echo "ok: a failed system fails the run and is named"

# Stopping a run ends a system that hangs. The system is a program of its own, as a container
# command is, because bash 3.2 (the macOS /bin/sh) can lose a TERM that reaches a shell function
# just before it blocks in a read. The stop comes after the program said it started. The test
# holds both ends of the FIFO the program reads, so a stop that fails frees it with a line and the
# test fails on the status (a system that was killed has 143) instead of waiting for ever.
hang() {
    exec sh -c 'echo "$1" >&7; read -r _ <"$2"' sh "$3" "$t/never"
}
mkfifo "$t/never"
exec 6<>"$t/never"
rm -rf "$t/out" && mkdir "$t/out"
open_started
start_systems "$t/out" prepare hang <<LIST
deb stuck
LIST
hand_over_started
read -r _ <&3 || fail "the system ended before it started"
exec 3<&-
stop_systems
echo released >&6
read -r pid <"$t/out/1.pid"
status=0
wait "$pid" 2>/dev/null || status=$?
[ "$status" -eq 143 ] || fail "stopping the run left the system running (status $status)"
echo "ok: stopping the run ends a system that hangs"
