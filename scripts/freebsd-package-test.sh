#!/bin/sh
# check-not-run: needs Docker, hardware virtualization (KVM) and the FreeBSD packages in dist/PROGRAM/freebsd (make package-freebsd, then make package-test-freebsd)
# The package test of both programs on FreeBSD (scripts/package-test-steps.sh), in one machine of each
# release of packaging/freebsd/releases, the way scripts/package-test.sh does it in a container
# for the other formats. FreeBSD cannot run in a container and has no channel to the host while it runs,
# so the host starts the machine twice (the image's vm.sh boots the same disk a second time):
#   first boot   the job (scripts/freebsd-package-test-job.sh) unpacks the input archive, runs phase 1 of
#                the steps, installs the one-shot rc.d script of the second boot and powers off;
#   second boot  the one-shot script runs phase 2 and phase 3 and powers off.
# The step that fails, and its lines, are printed by the machine; this script prints what came back.
# Every program whose package of the release is in dist/PROGRAM/freebsd/FreeBSD-MAJOR-amd64 is tested, the
# server first; a run of the client alone has the newest published server as its fixture, which the machine
# fetches (the client mounts from the server of its own system). Asking the server from outside is not
# possible here: the machine's steps ask from inside, and say so in their line. Environment: FREEBSD limits the run to one release, FREEBSD_IMAGE is the image
# of a release, with @RELEASE@ where it goes, VM_TIMEOUT is the most seconds one boot may take, and a
# VERSION given must be the recorded one of every program, as for the other formats.
# shellcheck disable=SC2154
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
. scripts/package-test-program-lib.sh
. scripts/freebsd-lib.sh
. scripts/freebsd-package-test-host-lib.sh
platform=freebsd/amd64
# scripts/package-lib.sh, which use_program sources, has the same function; this one is for the
# checks before a program is chosen.
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
given_version="${VERSION:-}"
work="$(mktemp -d)"
baselines="$work/baselines"
mkdir "$baselines"
# freebsd_run mounts this folder in the machine's container and reads its absolute path.
out="$work/out"
mkdir "$out"
# What a container wrote is root's on a Linux host, so a failed removal is not a failure of the run.
trap 'rm -rf "$work" 2>/dev/null || true' EXIT

all_programs="server client"

# The records of the builds are read from a copy, which also holds the record of a fixture, a published package
# that is no build (choose_fixtures), so that no build is needed for it and dist is not written.
records="$work/records"
for recorded in $all_programs; do
    [ -f "dist/$recorded/version" ] || continue
    mkdir -p "$records/$recorded"
    cp "dist/$recorded/version" "$records/$recorded/version"
done
record_folder="$records"

# The hook of scripts/package-test-program-lib.sh: the machine fetches the package itself, so the host
# says only whether a package is published (an empty file is none) and what the site listed when the run
# began, which is read once for the whole run, as scripts/package-test.sh does. The machine replaces
# the version with the one of the file it fetched, because the site can list a newer package by then.
prepare_baseline() {
    save_baseline_version
}

test_release() {
    release="$1"
    major="${release%%.*}"
    present=""
    for candidate in $all_programs; do
        # package_of is a function whose output is the answer, and its status is always 0.
        # shellcheck disable=SC2310
        package_path="$(package_of "$candidate" "$major")"
        if [ -n "$package_path" ]; then
            present="$present${present:+ }$candidate"
        else
            echo "FreeBSD $release: $candidate: no package, left out"
        fi
    done
    [ -n "$present" ] || fail "no FreeBSD package of release $release in dist/server/freebsd or dist/client/freebsd: run make package-freebsd first"
    # A run of the client alone mounts from the newest published server, which the machine fetches itself.
    choose_fixtures
    write_fixture_records
    job="$out/job-$release"
    # present is a list of words on purpose.
    # shellcheck disable=SC2086
    make_job_folder "$release" "$job" $present
    # present is a list of words on purpose.
    # shellcheck disable=SC2086
    make_input "$major" "$out/input-$release.tar" $present
    echo "FreeBSD $release: testing $present, two boots"
    freebsd_run "$release" "$job" "$out/result-$release" "$out/input-$release.tar"
    [ "$run_status" -eq 0 ] || fail "FreeBSD $release: the package test failed: the step and its lines are above"
    result="$(cat "$out/result-$release/package-test/result" 2>/dev/null)" || result="no result was written"
    [ "$result" = ok ] || fail "FreeBSD $release: $result"
    echo "ok   pkg FreeBSD $release"
}

freebsd_each_release test_release
