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
# the date $3 and the revision $4 left in the environment (empty: none), and prints what a
# program started afterwards sees as VERSION, PACKAGE_DATE and REVISION, which shows that all
# three are exported.
read_record() {
    # The inner shell expands $1 to $4, which are the root of the repository, the version, the
    # date and the revision.
    # shellcheck disable=SC2016
    (cd "$tree" && PROGRAM="$1" sh -c '
        set -e
        unset VERSION PACKAGE_DATE REVISION
        if [ -n "$2" ]; then VERSION="$2"; fi
        if [ -n "$3" ]; then PACKAGE_DATE="$3"; fi
        if [ -n "$4" ]; then REVISION="$4"; fi
        . "$1/scripts/package-record.sh"
        use_recorded_version
        sh -c "echo \$VERSION \$PACKAGE_DATE \$REVISION"' sh "$root" "$2" "$3" "$4" 2>&1)
}

# $1 case name, $2 PROGRAM, $3 VERSION given by hand, $4 PACKAGE_DATE of the environment, $5
# REVISION of the environment, $6 the "VERSION PACKAGE_DATE REVISION" that must be read.
reads() {
    # The status of read_record is the answer here, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    got="$(read_record "$2" "$3" "$4" "$5")" || true
    if [ "$got" = "$6" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$6" "$got"
        failed=$((failed + 1))
    fi
}

# $1 case name, $2 PROGRAM, $3 VERSION given by hand, $4 text the refusal must contain.
refuses() {
    # The status of read_record is the answer here, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if got="$(read_record "$2" "$3" "" "")"; then
        printf 'FAIL %s was accepted: %s\n' "$1" "$got"
        failed=$((failed + 1))
    elif printf '%s' "$got" | grep -qF -- "$4"; then
        printf 'ok   %s: %s\n' "$1" "$got"
    else
        printf 'FAIL %s was refused with the wrong message: %s\n' "$1" "$got"
        failed=$((failed + 1))
    fi
}

# $1 PROGRAM, $2 VERSION, $3 PACKAGE_DATE, $4 REVISION: the record make packages writes, in the
# fixture tree.
writes() {
    # The inner shell expands $1, which is the root of the repository.
    # shellcheck disable=SC2016
    (cd "$tree" && PROGRAM="$1" VERSION="$2" PACKAGE_DATE="$3" REVISION="$4" \
        sh -c '. "$1/scripts/package-record.sh"; write_package_record' sh "$root")
}

mkdir -p "$tree/dist/demo" "$tree/dist/other" "$tree/dist/broken" "$tree/dist/empty" "$tree/dist/norev"
writes demo v1.2.3 20261112 0
writes other v2.0.0-rc.1 20261113 3
printf 'VERSION=v1.2.3\n' > "$tree/dist/broken/version"
# A record of the version and the date only: written before packages had a revision, so the
# packages it describes are not known to be revision 0 and the record is not trusted.
printf 'VERSION=v1.2.3\nPACKAGE_DATE=20261112\n' > "$tree/dist/norev/version"
: > "$tree/dist/empty/version"

want_file="VERSION=v1.2.3
PACKAGE_DATE=20261112
REVISION=0"
record="$(cat "$tree/dist/demo/version")"
if [ "$record" = "$want_file" ]; then
    echo "ok   the record holds the version and the date, one to a line"
else
    printf 'FAIL the record is not what the tests read: %s\n' "$record"
    failed=$((failed + 1))
fi

reads "the recorded version is read and exported" demo "" "" "" "v1.2.3 20261112 0"
reads "each program has its own record" other "" "" "" "v2.0.0-rc.1 20261113 3"
reads "a version given by hand may be the recorded one" demo v1.2.3 "" "" "v1.2.3 20261112 0"
# The date and the revision belong to the build, so one left in the environment never replaces it.
reads "the recorded date wins over the environment" demo "" 20300101 "" "v1.2.3 20261112 0"
reads "the recorded revision wins over the environment" other "" "" 7 "v2.0.0-rc.1 20261113 3"
refuses "a version that is not the recorded one" demo v1.2.4 "v1.2.4 is not the recorded v1.2.3"
refuses "a program without a record" nothing "" "dist/nothing/version does not exist"
refuses "a record without the date" broken "" "dist/broken/version is damaged"
refuses "an empty record" empty "" "dist/empty/version is damaged"
refuses "a record without the revision" norev "" "dist/norev/version is damaged"

# make packages writes the record when every format is built, and any build removes the record
# first, so the record never describes a set of packages that is only partly built.
dry="$(cd "$root" && make -n --no-print-directory packages PROGRAM=demo BIN=/bin SRC=/tmp VERSION=v1.2.3 PACKAGE_DATE=20261112 REVISION=2 2>&1)" || true
last="$(printf '%s\n' "$dry" | tail -n 1)"
if printf '%s' "$last" | grep -q 'PROGRAM=demo VERSION=v1.2.3 PACKAGE_DATE=20261112 REVISION=2 .*write_package_record'; then
    echo "ok   make packages writes the record last, with the revision"
else
    printf 'FAIL make packages does not write the record last: %s\n' "$last"
    failed=$((failed + 1))
fi
# Every packager gets the revision, and without REVISION it is 0: the release itself.
if printf '%s\n' "$dry" | grep -c 'REVISION=2' | grep -qx 4; then
    echo "ok   make packages gives the revision to every format and to the record"
else
    printf 'FAIL make packages does not give REVISION=2 to the three formats and the record: %s\n' "$dry"
    failed=$((failed + 1))
fi
dry="$(cd "$root" && make -n --no-print-directory packages PROGRAM=demo BIN=/bin SRC=/tmp VERSION=v1.2.3 PACKAGE_DATE=20261112 2>&1)" || true
if printf '%s\n' "$dry" | grep -c 'REVISION=0' | grep -qx 4; then
    echo "ok   the revision is 0 when none is given"
else
    printf 'FAIL the revision is not 0 when none is given: %s\n' "$dry"
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
