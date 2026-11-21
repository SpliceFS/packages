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
# the host makes the file of the baseline there (save_baseline_version), the steps need nothing. A system
# that fetches its published package itself replaces the version in the file with the one of the file it
# got (record_baseline_version).
# shellcheck disable=SC2154 # the caller sets platform, baselines and given_version, the libraries the rest

# Writes the version of the published baseline of the program into its file in $baselines, once for the
# whole run, for the hook prepare_baseline of a host: the newest published package of the program,
# which step 1 installs and step 2 upgrades, is the version the record of the build names (the newest
# on the site when it names none). The file is empty when nothing is published.
save_baseline_version() {
    baseline_file="$baselines/$PROGRAM"
    [ ! -f "$baseline_file" ] || return 0
    # upgrade_from_version is a test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    upgrade_from_version >"$baseline_file.new" ||
        fail "could not read the newest published package of $PROGRAM from $site_url"
    mv "$baseline_file.new" "$baseline_file"
}

# A program that mounts from the server of the same system (its service check says it needs the cluster
# certificate) has nothing to mount from in a run without packages of the server: the newest published server
# is its fixture, installed in step 3. Sets $fixtures to the programs of the run that are no program under test
# but a fixture (empty, or server), for the programs in $present.
choose_fixtures() {
    fixtures=""
    case " $present " in
        *" server "*) return 0 ;;
        *) ;;
    esac
    for mounting_program in $present; do
        use_program "$mounting_program"
        if [ "${needs_cluster_certificate:-no}" = yes ]; then fixtures=server; fi
    done
}

# Writes the record of each fixture, which names the newest published version as its version, in the folder of
# the records (record_folder): the fixture is a published package that is no build, so make packages made no
# record for it. The host fetches and proves its file like a baseline.
write_fixture_records() {
    for fixture_program in $fixtures; do
        fixture_newest="$(sh scripts/published-newest.sh "$fixture_program")" ||
            fail "could not read the newest published package of $fixture_program from $site_root"
        [ "$fixture_newest" != "$nothing_published" ] ||
            fail "no package of $fixture_program is published and dist/$fixture_program has none: the $present has no $fixture_program to mount from"
        fixture_record="$(record_file "$fixture_program")"
        mkdir -p "$(dirname "$fixture_record")"
        fixture_version="$(package_release_of_debver "$fixture_newest")"
        # A shell of its own, so that the words of the record are not the words of the program that is chosen.
        PROGRAM="$fixture_program" VERSION="$fixture_version" UPGRADE_FROM="$fixture_newest" record_folder="${record_folder:-}" \
            sh -c '. scripts/package-record.sh; write_package_record'
        echo "$fixture_program: no packages; the newest published $fixture_program ($fixture_newest) is the fixture of the $present"
    done
}

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

# Records $1, the version of the published package that the system fetched itself (a system the host
# cannot reach: the hook published_baseline_version of its format reads it from the file it got), as the
# baseline of the program, and sets the words that follow from it again. The host read the site before
# the system fetched, and the site can list a newer package by then, so the file the system got is the
# only place that says which version it is. The record is the file of the program in $baselines, which
# the program chosen again, in this phase or the next, reads, so the version is read from the file once.
# A version that is not one of ours ends the caller, as set_baseline does.
record_baseline_version() {
    printf '%s\n' "$1" >"$baselines/$PROGRAM.new"
    mv "$baselines/$PROGRAM.new" "$baselines/$PROGRAM"
    set_baseline
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
    unset port health_path mount_point service_before_upgrade needs_cluster_certificate
    # shellcheck source=/dev/null
    . "$defs/service-check.sh"
    package_arches "$platform"
    if command -v prepare_baseline >/dev/null 2>&1; then prepare_baseline; fi
    set_baseline
    chosen_program="$1"
}
