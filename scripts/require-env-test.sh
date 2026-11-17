#!/bin/sh
# Test of scripts/require-env.sh (part of make check): it passes when every variable has a value,
# and otherwise fails and names each one that lacks it, without ever printing a value.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
failed=0

check() {
    name="$1"
    want="$2"
    shift 2
    status=0
    "$@" >"$out" 2>&1 || status=$?
    if [ "$status" -eq "$want" ]; then echo "ok   $name"; else
        echo "FAIL $name (status $status, wanted $want)"
        failed=$((failed + 1))
    fi
}

# Checks the output of the last run: $1 says what is checked, $2 is a pattern that must be in it
# and $3 one that must not be.
output() {
    if grep -q -e "$2" "$out" && ! grep -q -e "$3" "$out"; then echo "ok   $1"; else
        echo "FAIL $1"
        failed=$((failed + 1))
    fi
}

check "every variable has a value" 0 env FIRST=a SECOND=b sh "$root/scripts/require-env.sh" FIRST SECOND
check "an empty variable fails" 1 env FIRST=a SECOND= sh "$root/scripts/require-env.sh" FIRST SECOND
output "the empty variable is named and the other is not" '^::error::SECOND is empty' FIRST
check "a variable that is not set fails" 1 env FIRST=a sh "$root/scripts/require-env.sh" FIRST NEVER_SET
output "the variable that is not set is named" '^::error::NEVER_SET is empty' FIRST
check "every missing variable is named" 1 env ONE= TWO=hunter2 THREE= sh "$root/scripts/require-env.sh" ONE TWO THREE
output "both missing variables are named, and no value is printed" '^::error::THREE is empty' hunter2
check "no name is a usage error" 2 sh "$root/scripts/require-env.sh"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
