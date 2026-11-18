#!/bin/sh
# Test of the targets of the Makefile that stop a package test when the packages it needs are not
# in dist: a test that uses one format asks for that format only, a test that uses all of them
# asks for all. Runs on the host, no Docker. The Makefile runs in a folder of its own, with a
# dist folder that holds what each case needs.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# Makes dist/client of the folder $1 with the files named by the other arguments.
dist_with() {
    folder="$1"
    shift
    mkdir -p "$folder/dist/client"
    for file in "$@"; do
        mkdir -p "$folder/dist/client/$(dirname "$file")"
        : > "$folder/dist/client/$file"
    done
}

# $1 case name, $2 folder, $3 expected status (0 or not 0), then the arguments of make.
check() {
    case_name="$1"
    folder="$2"
    want_zero="$3"
    shift 3
    status=0
    make --no-print-directory -C "$folder" -f "$root/Makefile" "$@" >"$work/out" 2>&1 || status=$?
    if { [ "$want_zero" = zero ] && [ "$status" -eq 0 ]; } || { [ "$want_zero" = nonzero ] && [ "$status" -ne 0 ]; }; then
        printf 'ok   %s\n' "$case_name"
    else
        output="$(cat "$work/out")"
        printf 'FAIL %s: want %s, got status %s: %s\n' "$case_name" "$want_zero" "$status" "$output"
        failed=$((failed + 1))
    fi
}

dist_with "$work/apk-only" alpine/x86_64/splicefs-client-1.apk
dist_with "$work/all" alpine/x86_64/splicefs-client-1.apk splicefs-client_1.deb splicefs-client-1.rpm
mkdir -p "$work/empty/dist/client"

check "the Alpine packages alone are enough for a test that uses only them" "$work/apk-only" zero \
    built-apk-packages PROGRAM=client
check "a test that uses every format refuses Alpine packages alone" "$work/apk-only" nonzero \
    built-packages PROGRAM=client
check "every format is enough for a test that uses every format" "$work/all" zero \
    built-packages PROGRAM=client
check "no packages stops a test that uses only Alpine packages" "$work/empty" nonzero \
    built-apk-packages PROGRAM=client
check "no program stops a test that uses only Alpine packages" "$work/all" nonzero built-apk-packages

# The fstab test installs the Alpine package only, so it asks for that and for nothing more.
got="$(make -C "$work/all" -f "$root/Makefile" -pqR PROGRAM=client 2>/dev/null | grep '^fstab-test:' || true)"
if [ "$got" = "fstab-test: built-apk-packages" ]; then
    echo "ok   the fstab test asks for the Alpine packages only"
else
    echo "FAIL the fstab test needs '$got'"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "built packages: all cases as expected"
