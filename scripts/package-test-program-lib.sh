# shellcheck shell=sh
# Sourced from the root of the repository by the host's part of the package test
# (scripts/package-test.sh) and by its steps (scripts/package-test-steps.sh), after
# scripts/package-record.sh. It is the one place that says what choosing a program for the test sets,
# so that the host and the steps cannot disagree about a program: its version (what the record of its
# build says), the words of scripts/package-lib.sh and scripts/published-lib.sh (package names and
# versions), what its service check says (programs/PROGRAM/service-check.sh), and its baseline.
#
# The caller sets $platform (linux/amd64 or linux/arm64) and $baselines (the folder with one file for
# each program, which holds the version of its published baseline, empty when nothing is published),
# and may set $given_version (a VERSION given by hand, which must be the recorded one) and define
# prepare_baseline, which runs after the words of the program are set and before its baseline is read:
# the host fetches the baseline into the file there, the steps need nothing.
# shellcheck disable=SC2154 # the caller sets platform, baselines and given_version, the libraries the rest

# Sets $from (empty when nothing is published), and PUBLISHED_VERSION, which the scripts that run in
# the steps read: the program version of the published package, or the new one when there is none.
set_baseline() {
    from="$(cat "$baselines/$PROGRAM")"
    PUBLISHED_VERSION="$VERSION"
    if [ -n "$from" ]; then
        # A version that package_release_of_debver refuses ends the script here, with its message.
        use_published_version "$from"
        PUBLISHED_VERSION="$old_tag"
    fi
    export PUBLISHED_VERSION
}

# Chooses the program $1. What the service check of the program before it set and the next does not
# is unset first, so that it is not taken for the next program's. The words of a program do not change
# during a run, so choosing the program that is chosen already does nothing: the steps choose a program
# at the start of every step, and every choice costs a few dozen processes.
use_program() {
    [ "${chosen_program:-}" != "$1" ] || return 0
    PROGRAM="$1"
    export PROGRAM
    VERSION="${given_version:-}"
    # The status ends the run here, where errexit is off in a check; the function says why.
    # shellcheck disable=SC2310
    use_recorded_version || exit 1
    . scripts/package-lib.sh
    . scripts/published-lib.sh
    unset port health_path
    # shellcheck source=/dev/null
    . "$defs/service-check.sh"
    package_arches "$platform"
    if command -v prepare_baseline >/dev/null 2>&1; then prepare_baseline; fi
    set_baseline
    chosen_program="$1"
}
