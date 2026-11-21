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
# server first. Asking the server from outside is not possible here: the machine's steps ask from inside,
# and say so in their line. Environment: FREEBSD limits the run to one release, FREEBSD_IMAGE is the image
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

# Where the baseline of a program is read from the package site, once for the whole run, as
# scripts/package-test.sh does it: the machine fetches the package itself and needs only the version.
prepare_baseline() {
    baseline_file="$baselines/$PROGRAM"
    [ -f "$baseline_file" ] || {
        # upgrade_from_version is a test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        upgrade_from_version >"$baseline_file.new" ||
            fail "could not read the newest published package of $PROGRAM from $site_url"
        mv "$baseline_file.new" "$baseline_file"
    }
}

# Prints the package file of the program $1 for the release major version $2, or nothing.
package_of() {
    # A program that was not built has no record of its build, which use_program refuses.
    [ -f "dist/$1/version" ] || return 0
    use_program "$1"
    candidate="dist/$1/freebsd/FreeBSD-$2-amd64/$name-$pkgver.pkg"
    [ ! -f "$candidate" ] || echo "$candidate"
}

# Writes the input archive of the machine, $2, for the programs named by the other arguments and the
# release major version $1: the repository files the steps read, the package files, and the version of
# each baseline. The Mac's own attributes are left out: FreeBSD's tar reports them as errors.
make_input() {
    major="$1"
    archive="$2"
    shift 2
    stage="$work/input-$major"
    rm -rf "$stage"
    mkdir -p "$stage/src/dist" "$stage/pkg" "$stage/baselines"
    for copied in scripts programs steps keys packaging; do
        cp -RL "$root/$copied" "$stage/src/$copied"
    done
    for each in "$@"; do
        use_program "$each"
        mkdir -p "$stage/src/dist/$each" "$stage/pkg/$each"
        cp "$root/dist/$each/version" "$stage/src/dist/$each/version"
        package_path="$(package_of "$each" "$major")"
        cp "$package_path" "$stage/pkg/$each/"
        cp "$baselines/$each" "$stage/baselines/$each"
    done
    COPYFILE_DISABLE=1 tar -cf "$archive" -C "$stage" .
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
    job="$out/job-$release"
    # The job script runs the first boot; the file of the second boot and the template of its one-shot
    # script, which the image of the machine provides, are in the job folder too.
    # present is a list of words on purpose.
    # shellcheck disable=SC2086
    freebsd_job_folder "$release" "$job" scripts/freebsd-package-test-job.sh $present
    cp scripts/freebsd-package-test-second.sh "$job/"
    machine_image="$(freebsd_image "$release")"
    docker run --rm "$machine_image" cat /freebsd/second-boot.in >"$job/second-boot.in" ||
        fail "cannot read /freebsd/second-boot.in from $machine_image: the image is too old for a second boot"
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
