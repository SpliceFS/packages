# shellcheck shell=sh
# Sourced from the root of the repository. make packages records the version it built, and the
# date that goes into the version of a build that is not a release, in dist/PROGRAM/version.
# That file is the one place the tests that follow (package-test, service-test, repo-test,
# upgrade-test) take the version from, so none of them needs it given again, and a test can
# never run against packages of another version than the ones in dist.

# Writes the record from PROGRAM, VERSION and PACKAGE_DATE of the environment.
write_package_record() {
    : "${PROGRAM:?PROGRAM is not set}"
    : "${VERSION:?VERSION is not set}"
    : "${PACKAGE_DATE:?PACKAGE_DATE is not set}"
    printf 'VERSION=%s\nPACKAGE_DATE=%s\n' "$VERSION" "$PACKAGE_DATE" > "dist/$PROGRAM/version"
}

# Sets and exports VERSION and PACKAGE_DATE from the record of PROGRAM. A VERSION that is already
# set was given by hand, and it must be the recorded one: a test that is told another version
# than the one built would test packages that are not there. A PACKAGE_DATE of the environment is
# replaced, because the date belongs to the build, not to the test. Ends the caller when the
# record is missing, damaged or disagrees (called as a simple command, so errexit applies).
use_recorded_version() {
    record="dist/$PROGRAM/version"
    if [ ! -f "$record" ]; then
        echo "FAIL: $record does not exist: run make packages first" >&2
        return 1
    fi
    recorded_version="$(sed -n 's/^VERSION=//p' "$record")"
    recorded_date="$(sed -n 's/^PACKAGE_DATE=//p' "$record")"
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
    export VERSION PACKAGE_DATE
}
