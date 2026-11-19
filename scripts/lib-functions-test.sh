#!/bin/sh
# Fails when one shell function is defined in two of the libraries scripts/*-lib.sh, or twice in
# one. A script that sources both gets the definition of whichever it sources last, so the same
# name in two places means that a change to one of them is silently undone by the other. Every
# function has one home. The adapters of the package formats (scripts/service-test-<format>.sh)
# are not libraries: they define the same names on purpose, and a script sources one of them.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

twice="$(grep -Eho '^[A-Za-z_][A-Za-z_0-9]*\(\)' scripts/*-lib.sh | sort | uniq -d)"
if [ -n "$twice" ]; then
    for each in $twice; do
        echo "FAIL ${each} is defined more than once:"
        grep -l "^${each%()}()" scripts/*-lib.sh | sed 's/^/     /'
    done
    exit 1
fi
echo "ok   no function is defined twice in scripts/*-lib.sh"
