#!/bin/sh
# check: systems-lib.sh: every system starts at once, output in order, failures named, a stopped run ends its systems
# Test of run_systems in scripts/systems-lib.sh with stand-in commands instead of containers, so it
# needs no Docker. The stand-ins meet at FIFOs: each says it started and then waits to be released,
# and the test releases them only after every one has started, so a runner that started them one
# after another would never get past the first (the run is wrapped in a time limit in CI).
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

# Says it started, waits for its release, prints two lines and passes unless its image is "broken".
stand_in() {
    echo "$3" >"$t/started"
    read -r _ <"$t/go.$3"
    echo "ok   $1 $2"
    echo "     second line of $2"
    [ "$2" != broken ]
}

# Waits until N systems said they started, then releases them, the last one first, so they end in
# the opposite order of the list. Usage: release_all N
release_all() {
    exec 3<>"$t/started"
    seen=0
    while [ "$seen" -lt "$1" ]; do
        read -r _ <&3
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
    run_systems "$t/out" prepare stand_in >"$t/result" 2>&1 <<LIST &
$1
LIST
    runner=$!
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

# A system that hangs is ended when the run is stopped (the time limit of the job, Ctrl-C). The
# stand-in holds a FIFO open as long as it lives, so reading it to the end proves it has ended.
mkfifo "$t/held"
hang() {
    exec 4>"$t/held"
    echo "$3" >"$t/started"
    read -r _ <"$t/never"
}
mkfifo "$t/never"
rm -rf "$t/out" && mkdir "$t/out"
(
    trap 'stop_systems; exit 143' TERM
    run_systems "$t/out" prepare hang <<LIST
deb stuck
LIST
) >/dev/null 2>&1 &
runner=$!
exec 5<"$t/held"
exec 3<>"$t/started"
read -r _ <&3
kill -TERM "$runner"
status=0
wait "$runner" || status=$?
[ "$status" -eq 143 ] || fail "the stopped run ended with status $status"
cat <&5 >/dev/null
echo "ok: stopping the run ends a system that hangs"
