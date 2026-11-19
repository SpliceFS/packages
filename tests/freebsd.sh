#!/bin/sh
# Runs the setup script on FreeBSD itself: for every FreeBSD release in
# packaging/freebsd/releases it starts that release as a virtual machine and runs the job
# tests/freebsd-job.sh in it as root (make e2e-freebsd). Runs on the host and needs Docker and
# hardware virtualization (KVM). FreeBSD cannot run in a container, so the machine runs under
# QEMU inside the prepared image of the release (scripts/freebsd-lib.sh).
#
# No web server is needed. The site is the published setup script and the keys of the repository,
# and it travels into the machine as its input archive, so the self-check of the setup script
# reads the published site on the web, as people's machines do. Nothing is built.
#
# Environment: FREEBSD limits the run to one release (for example 15.1), empty means every
# release in the list; FREEBSD_IMAGE is the image of a release, with @RELEASE@ where the
# release goes; LINUX_IMAGE is the image that removes what the machine left, which belongs to
# root; VM_TIMEOUT is the most seconds one machine may run.
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
# shellcheck source=scripts/fetch-lib.sh
. scripts/fetch-lib.sh
# shellcheck source=scripts/published-site-lib.sh
. scripts/published-site-lib.sh

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# The container runs as root, so on Linux what it writes (the results folder) cannot be
# removed by the host user. The old results are removed in a container for that reason.
docker run --rm -v "$out":/out "$image" rm -rf /out/results

# Puts the site of the machine in $out/site.
prepare_site() {
    fetch_published_site "$out/site" "$root"
}

test_release() {
    release="$1"
    echo "FreeBSD $release: testing the published setup script"
    prepare_site
    mkdir -p "$out/input"
    archive="$out/input/$release.tar"
    # The machine unpacks the archive to /tmp/input, so the site folder is at its top. On
    # a Mac, tar would add files of its own for extended attributes, which FreeBSD's tar
    # reports as errors when it unpacks; both settings leave them out.
    COPYFILE_DISABLE=1 tar --no-xattrs -cf "$archive" -C "$out" site
    job="$out/job/$release"
    freebsd_job_folder "$release" "$job" tests/freebsd-job.sh
    # The job's output is standard output of the run; the machine's console on failure goes
    # to standard error, which stays on the screen.
    freebsd_run "$release" "$job" "$out/results" "$archive" > "$log"
    cat "$log"
    [ "$run_status" -eq 0 ] || fail "FreeBSD $release failed"
    last_line="$(tail -n 1 "$log")"
    [ "$last_line" = FREEBSD-SETUP-OK ] ||
        fail "FreeBSD $release: the job did not end with FREEBSD-SETUP-OK"
    echo "ok   FreeBSD $release"
}

freebsd_each_release test_release
