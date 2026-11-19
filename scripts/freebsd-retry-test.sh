#!/bin/sh
# check: freebsd-job.sh retry: a failing command is tried up to three times, stops at the first success, and says what failed
# Host test of the retry helper of the FreeBSD install job (tests/freebsd-job.sh): no machine,
# no pkg, no network, no waiting. A stand-in command fails a chosen number of times, and a
# stand-in for sleep records the pauses instead of waiting.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# $1 what is tested, $2 the text wanted, $3 the text got.
same() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

# The job runs alone in the machine, where no other file of the repository is, so the helper
# lives in the job and is read from there.
sed -n '/^retry() {$/,/^}$/p' "$root/tests/freebsd-job.sh" > "$work/retry.sh"
[ -s "$work/retry.sh" ] || { echo "FAIL: tests/freebsd-job.sh has no function retry" >&2; exit 1; }
# shellcheck source=/dev/null
. "$work/retry.sh"

# Stands in for sleep: the pause is recorded, so no test waits.
sleep() {
    echo "$1" >> "$work/sleeps"
}

# The stand-in command: fails its first $1 calls, then succeeds. Each call records its
# arguments, one line a call, in a file because the helper runs in a subshell of the test.
flaky() {
    failures="$1"
    shift
    printf '%s|' "$@" >> "$work/calls"
    echo >> "$work/calls"
    made="$(wc -l < "$work/calls")"
    [ "$((made))" -gt "$failures" ]
}

# $1 failures before the stand-in succeeds, $2 tries; the rest are the arguments of the
# stand-in. Leaves the status of the helper in $status and what it printed in $work/output.
run_retry() {
    failures="$1"
    tries="$2"
    shift 2
    : > "$work/calls"
    : > "$work/sleeps"
    status=0
    (retry "$tries" 7 "the server did not answer" flaky "$failures" "$@") > "$work/output" 2>&1 || status=$?
}

# Sets count to the number of lines of the file $1.
count_lines() {
    count="$(wc -l < "$1")"
    count="$((count))"
}

# what | failures before success | tries | wanted status | wanted calls | wanted pauses
while IFS='|' read -r name failures tries want_status want_calls want_pauses; do
    run_retry "$failures" "$tries" arg
    same "$name: status" "$want_status" "$status"
    count_lines "$work/calls"
    same "$name: calls" "$want_calls" "$count"
    count_lines "$work/sleeps"
    same "$name: pauses" "$want_pauses" "$count"
done <<'TABLE'
succeeds at once|0|3|0|1|0
succeeds on the second try|1|3|0|2|1
succeeds on the third try|2|3|0|3|2
fails every time, three tries|99|3|1|3|2
fails, one try allowed|99|1|1|1|0
TABLE

run_retry 99 3 arg
pauses="$(cat "$work/sleeps")"
same "the pause is the one asked for, between tries only" "7
7" "$pauses"
grep -qF -e "FAIL: the server did not answer after 3 tries" "$work/output" && found=yes || found=no
same "the failure message is printed after the last try" yes "$found"

run_retry 1 3 arg
if grep -qF -e "FAIL" "$work/output"; then found=yes; else found=no; fi
same "no failure message when a later try succeeds" no "$found"

run_retry 0 3 "two words" other
call="$(cat "$work/calls")"
same "the arguments reach the command unchanged" "two words|other|" "$call"

# How the job uses the helper. Only the preparation of the machine is retried, and the first
# line that runs the setup script comes after it, so the setup script starts only once the
# preparation returned success, and it runs once.
job="$root/tests/freebsd-job.sh"
prepare_line="$(grep -n '^retry 3 .* prepare_pkg || {$' "$job" | cut -d: -f1)"
setup_line="$(grep -n '^run_sh "[$]setup"' "$job" | head -n 1 | cut -d: -f1)"
if [ -n "$prepare_line" ] && [ "$prepare_line" -lt "${setup_line:-0}" ]; then order=before; else order=after; fi
same "the preparation, tried three times, comes before the first run of the setup script" before "$order"
same "the preparation refreshes the catalogs" 1 "$(grep -c 'pkg update -f' "$job" || true)"
same "the preparation upgrades pkg" 1 "$(grep -c 'pkg upgrade -y pkg' "$job" || true)"
# The helper is called once, for the preparation: nothing else is retried.
same "nothing but the preparation is retried" 1 "$(grep -c '^ *retry [0-9]' "$job" || true)"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed" >&2; exit 1; }
echo "freebsd-retry: the helper retries a failing command up to the tries given and stops at the first success"
