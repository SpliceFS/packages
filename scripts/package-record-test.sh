#!/bin/sh
# check: package-record.sh: the version make packages built, read by the tests
# Test of scripts/package-record.sh: make packages records the version it built in
# dist/PROGRAM/version and every test that follows reads it from there. Runs on the host, no
# Docker (part of make check). The Makefile cases use make -n, so nothing is built.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
failed=0

# Reads the record of the program $1 in the fixture tree, with the version $2 given by hand and
# the date $3 left in the environment (empty: none), and prints what a program started afterwards
# sees as VERSION, PACKAGE_DATE and UPGRADE_FROM (none when empty), which shows that all three are
# exported.
read_record() {
    # The inner shell expands $1 to $3, which are the root of the repository, the version and the
    # date.
    # shellcheck disable=SC2016
    (cd "$tree" && PROGRAM="$1" sh -c '
        set -e
        unset VERSION PACKAGE_DATE
        if [ -n "$2" ]; then VERSION="$2"; fi
        if [ -n "$3" ]; then PACKAGE_DATE="$3"; fi
        . "$1/scripts/package-record.sh"
        use_recorded_version
        sh -c "echo \$VERSION \$PACKAGE_DATE \${UPGRADE_FROM:-none}"' sh "$root" "$2" "$3" 2>&1)
}

# $1 case name, $2 PROGRAM, $3 VERSION given by hand, $4 PACKAGE_DATE of the environment, $5 the
# "VERSION PACKAGE_DATE UPGRADE_FROM" that must be read.
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

# $1 PROGRAM, $2 VERSION, $3 PACKAGE_DATE, $4 UPGRADE_FROM (empty: none): the record
# make packages writes, in the fixture tree.
writes() {
    # The inner shell expands $1, which is the root of the repository.
    # shellcheck disable=SC2016
    (cd "$tree" && PROGRAM="$1" VERSION="$2" PACKAGE_DATE="$3" UPGRADE_FROM="${4:-}" \
        sh -c '. "$1/scripts/package-record.sh"; write_package_record' sh "$root")
}

mkdir -p "$tree/dist/demo" "$tree/dist/other" "$tree/dist/broken" "$tree/dist/empty"
writes demo v1.2.3 20261112
writes other v2.0.0-rc.1 20261113 v2.0.0-rc.1
printf 'VERSION=v1.2.3\n' > "$tree/dist/broken/version"
: > "$tree/dist/empty/version"

want_file="VERSION=v1.2.3
PACKAGE_DATE=20261112
UPGRADE_FROM="
record="$(cat "$tree/dist/demo/version")"
if [ "$record" = "$want_file" ]; then
    echo "ok   the record holds the version, the date and the release to upgrade from, one to a line"
else
    printf 'FAIL the record is not what the tests read: %s\n' "$record"
    failed=$((failed + 1))
fi

reads "the recorded version is read and exported" demo "" "" "v1.2.3 20261112 none"
reads "each program has its own record, with the release it upgrades from" other "" "" "v2.0.0-rc.1 20261113 v2.0.0-rc.1"
reads "a version given by hand may be the recorded one" demo v1.2.3 "" "v1.2.3 20261112 none"
# The date belongs to the build, so one left in the environment never replaces it.
reads "the recorded date wins over the environment" demo "" 20300101 "v1.2.3 20261112 none"
# The release to upgrade from belongs to the build as well: one left in the environment must
# never send a test to another release than the one the packages were built next to.
# shellcheck disable=SC2016
got="$(cd "$tree" && PROGRAM=demo UPGRADE_FROM=v9.9.9 sh -c '. "$1/scripts/package-record.sh"; use_recorded_version; echo "${UPGRADE_FROM:-none}"' sh "$root")"
if [ "$got" = none ]; then
    echo "ok   the recorded release to upgrade from wins over the environment"
else
    printf 'FAIL an UPGRADE_FROM of the environment replaced the record: %s\n' "$got"
    failed=$((failed + 1))
fi
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
# The release to upgrade from is given to the record only: no packager has a use for it.
from_dry="$(cd "$root" && make -n --no-print-directory packages PROGRAM=demo BIN=/bin SRC=/tmp VERSION=v1.2.3 PACKAGE_DATE=20261112 UPGRADE_FROM=v1.2.2 2>&1)" || true
from_count="$(printf '%s\n' "$from_dry" | grep -c 'UPGRADE_FROM=v1.2.2' || true)"
from_last="$(printf '%s\n' "$from_dry" | tail -n 1)"
if [ "$from_count" = 1 ] && printf '%s' "$from_last" | grep -q 'UPGRADE_FROM=v1.2.2 .*write_package_record'; then
    echo "ok   make packages gives the release to upgrade from to the record only"
else
    printf 'FAIL make packages does not give UPGRADE_FROM to the record alone: %s\n' "$from_dry"
    failed=$((failed + 1))
fi
# A package is published only for a new release of its program, so there is no revision to give.
if printf '%s\n' "$dry" | grep -q REVISION; then
    printf 'FAIL make packages still gives a REVISION: %s\n' "$dry"
    failed=$((failed + 1))
else
    echo "ok   make packages gives no revision to any format or to the record"
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
