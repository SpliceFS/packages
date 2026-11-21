#!/bin/sh
# check-not-run: needs Docker and the packages in dist/server and dist/client (make package-test)
# Tests the new packages of the programs server and client on every system in packaging/test-systems,
# all at the same time, in ONE boot of the server image per system (its service manager is process 1),
# the way a person installs a package file: no repository and no setup script. Every program whose
# folder dist/PROGRAM holds packages is tested in that one boot, the server first; the folder of a
# program is mounted at /pkg/PROGRAM, and a program whose folder is missing or empty is left out
# ("PROGRAM: no packages, left out").
#
# This script is the host's part and does nothing to a system but start it, run the steps in it,
# restart it and read what they wrote. The steps themselves, and what each of them checks, are in
# scripts/package-test-steps.sh, which runs inside the system with what the system has. Per system:
#   1. the container is started with the repository (read only) at /src, the package folders at
#      /pkg/PROGRAM (they hold the published baseline files, which this script fetched once for the
#      whole run from the package site and proved by its signed index, scripts/published-verify.sh),
#      the public signing keys at /keys, and the version of each baseline at /baselines;
#   2. docker exec runs phase 1 of the steps (steps 0 to 4 and the restart of the service);
#   3. docker restart restarts the container, the way a machine is rebooted;
#   4. docker exec runs phase 2 (the rest of step 5, and the steps 7 to 9);
#   5. the output folder of the steps is copied out of the container: its log is printed and its
#      result is "ok" or the line of the step that failed.
# A failing system does not stop the others, so one run shows every system that is broken. Runs on
# the host (make package-test, CI). Environment: the version of each program comes from
# dist/PROGRAM/version, which make packages wrote (scripts/package-record.sh), and a VERSION given
# must be that one for every program in the run; PLATFORM (linux/amd64 or linux/arm64) tests that CPU
# type by emulation, empty means this machine's own; ONLY limits the run to one format or image.
#
# What differs between package formats is in scripts/service-test-<format>.sh and
# scripts/package-test-<format>.sh, which only the steps read; this script needs their files to exist.
# shellcheck disable=SC2154
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
. scripts/systems-lib.sh
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
work="$(mktemp -d)"
# What the systems get from the host, read only: the public signing keys of the package site, which
# step 1 gives the package managers of the systems (mounted at /keys, filled by fetch_baselines),
# and the version of each program's baseline (mounted at /baselines, one file for each program).
keys_dir="$work/keys"
baselines_dir="$work/baselines"
mkdir "$keys_dir" "$baselines_dir"
# Where in the system the steps write their log and their result. It is on the system's own disk, which
# a restart keeps, and scripts/lifecycle-excluded leaves it out of the snapshots.
out_dir=/var/tmp/package-test
# Every container of this run carries the process id of this run in its name, so the cleanup finds
# all of them and no other run's.
prefix="splicefs-package-test-$$"
cleanup() {
    stop_systems
    docker ps -aq --filter "name=$prefix-" | xargs docker rm -f >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# A VERSION given by hand must be the recorded one of every program in the run.
given_version="${VERSION:-}"

# The programs of a run, in the order they are tested.
all_programs="server client"

# Whether dist/$1 holds packages: a missing or empty folder is a program that is not tested.
has_packages() {
    for entry in "dist/$1"/* "dist/$1"/.[!.]*; do
        [ -e "$entry" ] && return 0
    done
    return 1
}

present=""
for candidate in $all_programs; do
    # has_packages is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if has_packages "$candidate"; then
        present="$present${present:+ }$candidate"
    else
        echo "$candidate: no packages, left out"
    fi
done
if [ -z "$present" ]; then
    echo "FAIL: no packages in dist/server or dist/client: run make packages first" >&2
    exit 1
fi

# The newest published package of the program, which step 1 installs and step 2 upgrades: the version
# the record of the build names (the newest on the site when it names none). The site is asked
# once for each program of the run, by the first call, before any system starts, and the answer is
# kept in the file of the program in $baselines_dir for the systems. Sets $from, empty when nothing is
# published.
set_baseline() {
    baseline_file="$baselines_dir/$PROGRAM"
    if [ ! -f "$baseline_file" ]; then
        # upgrade_from_version is a test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        upgrade_from_version >"$baseline_file.new" ||
            fail "could not read the newest published package of $PROGRAM from $site_url"
        mv "$baseline_file.new" "$baseline_file"
    fi
    from="$(cat "$baseline_file")"
    if [ -n "$from" ]; then
        # A version that package_release_of_debver refuses ends the script here, with its message.
        use_published_version "$from"
    fi
}

# Chooses the program $1: what the record of its build says (its version), what scripts/package-lib.sh
# makes of that (the package names and versions), where its published package is, and the published
# baseline.
use_program() {
    PROGRAM="$1"
    export PROGRAM
    VERSION="$given_version"
    # The status ends the run here, where errexit is off in a system; the function says why.
    # shellcheck disable=SC2310
    use_recorded_version || exit 1
    . scripts/package-lib.sh
    . scripts/published-lib.sh
    package_arches "$platform"
    published_dir="$root/dist/$PROGRAM/published"
    set_baseline
}

# Runs phase $1 of scripts/package-test-steps.sh in the container, as the root of the system, with
# what the steps need to know that the system cannot know itself.
run_phase() {
    docker exec -e FORMAT="$format" -e PLATFORM="$platform" -e PROGRAMS="$present" -e PACKAGE_TEST_OUT="$out_dir" \
        -w /src "$container" sh scripts/package-test-steps.sh "$1"
}

# The service manager of the container is up before a phase starts: after the boot and after the restart.
wait_until_booted() {
    # wait_booted is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_booted "$format" "$container" || {
        echo "--- last 30 lines of the container output"
        docker logs --tail 30 "$container" 2>&1 || true
        fail "the service manager did not finish booting"
    }
}

# Both phases with the restart between them; the status is that of the first one that fails. The
# caller runs this in a subshell so that fail ends only this system.
run_phases() {
    wait_until_booted
    # run_phase is one command whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    run_phase phase1 || return 1
    docker restart "$container" >/dev/null || fail "docker restart failed"
    wait_until_booted
    run_phase phase2
}

# One system, in a container and a folder of its own: number $3 of the list. It runs in a process of
# its own, so the functions of its format, sourced there, are its own too.
# Usage: test_system FORMAT IMAGE NUMBER.
test_system() {
    format="$1"
    image="$2"
    container="$prefix-$3"
    own="$work/system-$3"
    mkdir "$own"
    log="$own/log"
    started=0
    # The folder of each program is mounted at /pkg/PROGRAM.
    set -- --name "$container" --platform "$platform" -v "$root":/src:ro -v "$keys_dir":/keys:ro \
        -v "$baselines_dir":/baselines:ro
    for system_program in $present; do
        set -- "$@" -v "$root/dist/$system_program":"/pkg/$system_program":ro
    done
    # boot_system is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if boot_system "$@" "$image" 2>"$log"; then
        started=1
    fi

    # Errexit is switched off here on purpose: a failing phase must end only this system, not the
    # whole run.
    checked=1
    if [ "$started" -eq 1 ]; then
        set +e
        (run_phases) >>"$log" 2>&1
        checked=$?
        set -e
        # The output of the steps is read after the last phase that ran, also when it failed.
        mkdir "$own/out"
        docker cp "$container:$out_dir/." "$own/out" >>"$log" 2>&1 || true
        if [ -f "$own/out/log" ]; then cat "$own/out/log" >>"$log"; fi
    fi
    cat "$log"
    result="$(cat "$own/out/result" 2>/dev/null)" || result="no result was written"
    if [ "$checked" -eq 0 ] && [ "$result" = ok ]; then
        echo "ok   $format $image"
    else
        # The result names the step the steps stopped in; when they wrote none, there is no step to name.
        case "$result" in
            "step "*)
                reached="${result#step }"
                reached=" (step ${reached%%:*})"
                ;;
            *) reached="" ;;
        esac
        echo "FAIL $format $image$reached"
        echo "     $result"
        checked=1
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$checked"
}

# Choosing the first program is what sources scripts/package-lib.sh, which has the helpers every
# step below uses (fail, must, system_selected, boot_system).
use_program "${present%% *}"

systems="$(cat packaging/test-systems)"
selected=""
# A here-document keeps the list in this shell; a pipe would run the loop in a subshell.
while read -r format image; do
    # Blank lines and comments are skipped; every other line is a system to test.
    case "$format" in "" | "#"*) continue ;; *) ;; esac
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
    for needed in "scripts/service-test-$format.sh" "scripts/package-test-$format.sh"; do
        [ -f "$needed" ] || fail "$needed does not exist"
    done
    selected="$selected$format $image
"
done <<LIST
$systems
LIST

# Downloads the signing keys of the site once, and the published package file of every format that is
# tested, for each program of the run, once for all the systems of the format. The keys are proven to
# be the repository's keys, a package file by the signed index of the site. A download that fails ends
# the run before any system starts: it is not a failure of the package. Choosing the program is what
# reads its baseline from the site, for the systems too.
fetch_baselines() {
    for baseline_program in $present; do
        use_program "$baseline_program"
        [ -n "$from" ] || continue
        # The keys are needed once, by the first program that has a published package.
        # download_published_keys is a test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        [ -f "$keys_dir/splicefs.asc" ] || download_published_keys "$keys_dir" ||
            fail "could not download and verify the signing keys at $site_root/keys"
        for baseline_format in $(printf '%s\n' "$selected" | awk 'NF { print $1 }' | LC_ALL=C sort -u); do
            baseline_path="$(published_path "$baseline_format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
            # download_published_file is a test whose status is the answer, so set -e being off inside it
            # changes nothing.
            # shellcheck disable=SC2310
            download_published_file "$baseline_path" "$published_dir" ||
                fail "could not download and verify $site_url/$baseline_path"
        done
    done
}
fetch_baselines

run_systems "$work" pull_system test_system <<LIST
$selected
LIST
