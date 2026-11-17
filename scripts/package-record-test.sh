#!/bin/sh
# Test of scripts/package-record.sh: make packages records the version it built in
# dist/PROGRAM/version and every test that follows reads it from there. Runs on the host, no
# Docker (part of make check). The Makefile cases use make -n, so nothing is built.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
failed=0

# Reads the record of the program $1 in the fixture tree, with the version $2 given by hand and
# the date $3 left in the environment (empty: none), and prints what a program started
# afterwards sees as VERSION and PACKAGE_DATE, which shows that both are exported.
read_record() {
    # The inner shell expands $1, $2 and $3, which are the root of the repository, the version
    # and the date.
    # shellcheck disable=SC2016
    (cd "$tree" && PROGRAM="$1" sh -c '
        set -e
        unset VERSION PACKAGE_DATE
        if [ -n "$2" ]; then VERSION="$2"; fi
        if [ -n "$3" ]; then PACKAGE_DATE="$3"; fi
        . "$1/scripts/package-record.sh"
        use_recorded_version
        sh -c "echo \$VERSION \$PACKAGE_DATE"' sh "$root" "$2" "$3" 2>&1)
}

# $1 case name, $2 PROGRAM, $3 VERSION given by hand, $4 PACKAGE_DATE of the environment, $5 the
# "VERSION PACKAGE_DATE" that must be read.
reads() {
    # The status of read_record is the answer here, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    got="$(read_record "$2" "$3" "$4")" || true
    if [ "$got" = "$5" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$5" "$got"
        failed=$((failed + 1))
    fi
}

# $1 case name, $2 PROGRAM, $3 VERSION given by hand, $4 text the refusal must contain.
refuses() {
    # The status of read_record is the answer here, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if got="$(read_record "$2" "$3" "")"; then
        printf 'FAIL %s was accepted: %s\n' "$1" "$got"
        failed=$((failed + 1))
    elif printf '%s' "$got" | grep -qF -- "$4"; then
        printf 'ok   %s: %s\n' "$1" "$got"
    else
        printf 'FAIL %s was refused with the wrong message: %s\n' "$1" "$got"
        failed=$((failed + 1))
    fi
}

# $1 PROGRAM, $2 VERSION, $3 PACKAGE_DATE: the record make packages writes, in the fixture tree.
writes() {
    # The inner shell expands $1, which is the root of the repository.
    # shellcheck disable=SC2016
    (cd "$tree" && PROGRAM="$1" VERSION="$2" PACKAGE_DATE="$3" \
        sh -c '. "$1/scripts/package-record.sh"; write_package_record' sh "$root")
}

mkdir -p "$tree/dist/demo" "$tree/dist/other" "$tree/dist/broken" "$tree/dist/empty"
writes demo v1.2.3 20261112
writes other v2.0.0-rc.1 20261113
printf 'VERSION=v1.2.3\n' > "$tree/dist/broken/version"
: > "$tree/dist/empty/version"

want_file="VERSION=v1.2.3
PACKAGE_DATE=20261112"
record="$(cat "$tree/dist/demo/version")"
if [ "$record" = "$want_file" ]; then
    echo "ok   the record holds the version and the date, one to a line"
else
    printf 'FAIL the record is not what the tests read: %s\n' "$record"
    failed=$((failed + 1))
fi

reads "the recorded version is read and exported" demo "" "" "v1.2.3 20261112"
reads "each program has its own record" other "" "" "v2.0.0-rc.1 20261113"
reads "a version given by hand may be the recorded one" demo v1.2.3 "" "v1.2.3 20261112"
# The date is the date of the build, so one left in the environment never replaces it.
reads "the recorded date wins over the environment" demo "" 20300101 "v1.2.3 20261112"
refuses "a version that is not the recorded one" demo v1.2.4 "v1.2.4 is not the recorded v1.2.3"
refuses "a program without a record" nothing "" "dist/nothing/version does not exist"
refuses "a record without the date" broken "" "dist/broken/version is damaged"
refuses "an empty record" empty "" "dist/empty/version is damaged"

# make packages writes the record when every format is built, and any build removes the record
# first, so the record never describes a set of packages that is only partly built.
dry="$(cd "$root" && make -n --no-print-directory packages PROGRAM=demo BIN=/bin SRC=/tmp VERSION=v1.2.3 PACKAGE_DATE=20261112 2>&1)" || true
last="$(printf '%s\n' "$dry" | tail -n 1)"
if printf '%s' "$last" | grep -q 'PROGRAM=demo VERSION=v1.2.3 PACKAGE_DATE=20261112 .*write_package_record'; then
    echo "ok   make packages writes the record last"
else
    printf 'FAIL make packages does not write the record last: %s\n' "$last"
    failed=$((failed + 1))
fi
dry="$(cd "$root" && make -n --no-print-directory package-deb PROGRAM=demo BIN=/bin SRC=/tmp VERSION=v1.2.4 2>&1)" || true
if printf '%s\n' "$dry" | grep -q 'rm -f "dist/demo/version"' && ! printf '%s\n' "$dry" | grep -q write_package_record; then
    echo "ok   a build of one format removes the record and writes none"
else
    printf 'FAIL a build of one format leaves the record as it was: %s\n' "$dry"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "package record: all cases as expected"
