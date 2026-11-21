# shellcheck shell=sh
# Sourced from the root of the repository. make packages records the version it built, the
# date that goes into the version of a build that is not a release, and the release the upgrade
# tests start from, in dist/PROGRAM/version.
# That file is the one place the tests that follow (package-test, repo-test) take the version from, so none of them needs it given again, and a test can
# never run against packages of another version than the ones in dist.

# The folder of the records is dist, unless the caller sets record_folder: the host of the package test reads
# the records from the copy of the repository its systems read, which also holds the record of a published
# package that is no build (the fixture of a run of the client alone). Usage: record_file PROGRAM.
record_file() {
    echo "${record_folder:-dist}/$1/version"
}

# Writes the record from PROGRAM, VERSION and PACKAGE_DATE of the environment, and from
# UPGRADE_FROM, the version of the newest package of the program on the package site, as the apt
# index writes it (0.5.34; scripts/published-newest.sh), which the caller read once for the whole
# run: every job of the run then starts its upgrade from that package, also when a newer one is
# published meanwhile, which would turn the upgrade into a downgrade. The word none when the caller
# read the site and it lists no package of the program; empty when the caller did not read the
# site, and the tests then ask it themselves.
write_package_record() {
    : "${PROGRAM:?PROGRAM is not set}"
    : "${VERSION:?VERSION is not set}"
    : "${PACKAGE_DATE:?PACKAGE_DATE is not set}"
    printf 'VERSION=%s\nPACKAGE_DATE=%s\nUPGRADE_FROM=%s\n' \
        "$VERSION" "$PACKAGE_DATE" "${UPGRADE_FROM:-}" > "$(record_file "$PROGRAM")"
}

# Sets and exports VERSION, PACKAGE_DATE and UPGRADE_FROM from the record of PROGRAM. A
# VERSION that is already set was given by hand, and it must be the recorded one: a test that is
# told another version than the one built would test packages that are not there. A PACKAGE_DATE or
# UPGRADE_FROM of the environment is replaced, because they belong to the build, not to the test;
# a record without UPGRADE_FROM leaves it empty. Ends the caller when the record is missing,
# damaged or disagrees (called as a simple command, so errexit applies).
use_recorded_version() {
    record="$(record_file "$PROGRAM")"
    if [ ! -f "$record" ]; then
        echo "FAIL: $record does not exist: run make packages first" >&2
        return 1
    fi
    recorded_version="$(sed -n 's/^VERSION=//p' "$record")"
    recorded_date="$(sed -n 's/^PACKAGE_DATE=//p' "$record")"
    UPGRADE_FROM="$(sed -n 's/^UPGRADE_FROM=//p' "$record")"
    if [ -z "$recorded_version" ] || [ -z "$recorded_date" ]; then
        echo "FAIL: $record is damaged: run make packages again" >&2
        return 1
    fi
    if [ -n "${VERSION:-}" ] && [ "$VERSION" != "$recorded_version" ]; then
        echo "FAIL: $VERSION is not the recorded $recorded_version: the packages in dist/$PROGRAM were built as $recorded_version; leave VERSION out, or run make packages" >&2
        return 1
    fi
    VERSION="$recorded_version"
    PACKAGE_DATE="$recorded_date"
    export VERSION PACKAGE_DATE UPGRADE_FROM
}
