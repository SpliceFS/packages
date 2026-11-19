#!/bin/sh
# check: number-tags.sh: which tag names are versions of this repository
# Test of scripts/number-tags.sh: which tag names are version tags, and in what order. Runs on
# the host, no network (part of make check).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
failed=0

# $1 case name, $2 the tag names (one per line), $3 what must be printed (one per line).
numbers() {
    got="$(printf '%s' "$2" | sh scripts/number-tags.sh)"
    if [ "$got" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$3" "$got"
        failed=$((failed + 1))
    fi
}

numbers "no tags, no numbers" "" ""
numbers "plain numbers are kept" "1
2
3" "1
2
3"
numbers "numbers are ordered as numbers, not as text" "10
9
100
2" "2
9
10
100"
numbers "version tags are ignored" "v0.4.20
7
v1.0.0
8" "7
8"
numbers "zero, signs, leading zeros, decimals and words are not numbers" "0
01
+3
-3
1.5
3a
a3
5" "5"
numbers "a number longer than the shell can add is still ordered right" "99999999999999999999
100000000000000000000
12" "12
99999999999999999999
100000000000000000000"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "number-tags: all cases as expected"
