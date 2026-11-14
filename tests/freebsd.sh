#!/bin/sh
# Runs the setup script on FreeBSD itself: for every FreeBSD release in
# packaging/freebsd/images it starts that release as a virtual machine and runs the job
# tests/freebsd-job.sh in it as root (make e2e-freebsd). Runs on the host and needs Docker,
# curl and xz. FreeBSD cannot run in a container, so the machine runs under QEMU inside a
# Linux container (scripts/freebsd-vm.sh).
#
# No web server is needed. The test site is built for the base address
# file:///tmp/input/site and travels into the machine as its input archive, so the setup
# script's self-check (fetch of its own hash) reads the site folder inside the machine.
#
# Environment: FREEBSD limits the run to one release (for example 15.1), empty means every
# release in the list; LINUX_IMAGE is the container image QEMU is installed into;
# VM_TIMEOUT is the most seconds one machine may run.
set -eu

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
image="${LINUX_IMAGE:?LINUX_IMAGE is not set}"
mkdir -p dist/freebsd-e2e
out="$(cd dist/freebsd-e2e && pwd)"
# shellcheck source=scripts/freebsd-lib.sh
. scripts/freebsd-lib.sh

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# The container runs as root, so on Linux what it writes (the results folder) cannot be
# removed by the host user. The old results are removed in a container for that reason.
docker run --rm -v "$out":/out "$image" rm -rf /out/results

# Makes the folder the machine reads at its first boot, like freebsd_job_folder in the
# library. The library takes its job from scripts/, and this job lives in tests/.
job_folder() {
    folder="$1"
    rm -rf "$folder"
    mkdir -p "$folder"
    cp tests/freebsd-job.sh "$folder/"
    sed -e 's|@JOB@|freebsd-job.sh|' -e 's|@ARGS@||' packaging/freebsd/user-data.in > "$folder/user-data"
    printf 'instance-id: %s\nlocal-hostname: test\n' "$(basename "$folder")" > "$folder/meta-data"
}

test_release() {
    release="$1"
    disk="$2"
    echo "FreeBSD $release ($machine): testing the setup script"
    # The base address is a folder of the machine: see the top of this file. The site is
    # built on the host, where scripts/build-site.sh has its tools.
    KEYS_DIR=keys BASE_URL=file:///tmp/input/site ALLOW_FILE_BASE_URL=1 SITE_DIR="$out/site" \
        sh scripts/build-site.sh
    mkdir -p "$out/input"
    archive="$out/input/$release.tar"
    # The machine unpacks the archive to /tmp/input, so the site folder is at its top. On
    # a Mac, tar would add files of its own for extended attributes, which FreeBSD's tar
    # reports as errors when it unpacks; both settings leave them out.
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$archive" -C "$out" site
    job="$out/job/$release"
    job_folder "$job"
    # The job's output is standard output of the run; the machine's console on failure goes
    # to standard error, which stays on the screen.
    freebsd_run "$disk" "$job" "$out/results" "$archive" > "$log"
    cat "$log"
    [ "$run_status" -eq 0 ] || fail "FreeBSD $release ($machine) failed"
    last_line="$(tail -n 1 "$log")"
    [ "$last_line" = FREEBSD-SETUP-OK ] ||
        fail "FreeBSD $release ($machine): the job did not end with FREEBSD-SETUP-OK"
    echo "ok   FreeBSD $release ($machine)"
}

freebsd_each_release test_release
