#!/bin/sh
# Builds the FreeBSD packages and proves them, on FreeBSD itself: for every FreeBSD release
# in packaging/freebsd/releases it starts that release as a virtual machine (its prepared
# image, scripts/freebsd-lib.sh), where pkg(8) builds the package for amd64 and for arm64,
# installs the amd64 one and checks that the service runs (scripts/freebsd-job.sh). The
# machine is amd64, so the arm64 package is built there for another ABI and is not installed;
# scripts/freebsd-package-check.sh shows that it is an arm64 package. It runs on the host
# (make package-freebsd) and needs Docker and hardware virtualization (KVM).
#
# The machine also builds the signed package repository: it gets the keys and the packages
# published before (OUTPUT_DIR/repo/freebsd/FreeBSD:<major>:<cpu>/) and returns the folders
# repo/FreeBSD:<major>:<cpu>/ with the new package and the catalog pkg repo wrote. They are merged
# into OUTPUT_DIR/repo/freebsd/, which scripts/publish.sh sends.
#
# Environment: PROGRAM, VERSION and PACKAGE_DATE as for every package; BIN is the folder of
# the compiled programs on this computer, laid out <os>-<arch>/<program> (the programs of
# every system are in it; here the freebsd ones are used); KEYS_DIR is the folder of the
# signing keys (scripts/signing-keys.sh), dist/keys when not given; FREEBSD limits the run to
# one release (for example 15.1), empty means every release in the list; FREEBSD_IMAGE is
# the image of a release, with @RELEASE@ where the release goes; LINUX_IMAGE is the Go image,
# where the files of the repository are handled and the packages are checked; VM_TIMEOUT is
# the most seconds one machine may run.

# What program.conf sets (name, program, programs) is unknown to ShellCheck, which cannot follow it.
# shellcheck disable=SC2154
set -eu

out="${1:?usage: package-freebsd.sh OUTPUT_DIR}"
. scripts/package-lib.sh
image="${LINUX_IMAGE:?LINUX_IMAGE is not set}"
bin="$(cd "${BIN:?BIN is not set}" && pwd)"
out="$(cd "$out" && pwd)"
. scripts/freebsd-lib.sh

for arch in amd64 arm64; do
    for each in $programs; do
        [ -f "$bin/freebsd-$arch/$each" ] ||
            fail "$bin/freebsd-$arch/$each does not exist; BIN must hold the programs built for freebsd-$arch"
    done
done

keys="$(cd "${KEYS_DIR:-dist/keys}" && pwd)"
[ -f "$keys/splicefs.rsa" ] && [ -f "$keys/splicefs.rsa.pub" ] ||
    fail "the signing keys are missing in $keys; run make keys first"
published="$out/repo/freebsd"

# Runs one step of scripts/freebsd-repo-files.sh as root in the Linux container, where the
# signing key and the files a machine returned can be read and removed. On Linux the host
# user can do neither: both belong to root.
repo_files() {
    source_folder="$(pwd)"
    docker run --rm --user 0 -v "$source_folder":/src:ro -v "$out":/out -v "$keys":/keys:ro "$image" \
        sh /src/scripts/freebsd-repo-files.sh "$@"
}

# Looks at what the machine built, in the Go container, which has the tools. The package of
# the CPU type the machine does not have is never installed, so this is where a package that
# names one ABI and holds a program of another is stopped. Every program of the package is
# looked at, one call each.
check_packages() {
    source_folder="$(pwd)"
    user_id="$(id -u)"
    group_id="$(id -g)"
    for abiarch in amd64 aarch64; do
        for each in $programs; do
            docker run --rm --user "$user_id:$group_id" -v "$source_folder":/src:ro -v "$out":/out:ro "$image" \
                sh /src/scripts/freebsd-package-check.sh "/out/freebsd/FreeBSD-$1-$abiarch/$name-$pkgver.pkg" \
                "$1" "$abiarch" "$each"
        done
    done
}

build_and_test() {
    release="$1"
    job="$out/freebsd-job/$release"
    freebsd_job_folder "$release" "$job" scripts/freebsd-job.sh "$name" "$program" "$pkgver" "$VERSION"
    for arch in amd64 arm64; do
        for each in $programs; do
            cp "$bin/freebsd-$arch/$each" "$job/$each-$arch"
        done
    done
    # The definitions of the program: its rc script is named after the service program.
    cp "$defs/freebsd/$program.rc" "$defs/freebsd/manifest.in" "$defs/freebsd/plist" \
        "$defs/freebsd/check-lib.sh" "$job/"
    echo "FreeBSD $release: building $name $pkgver for amd64 and arm64, installing the amd64 package"
    major="${release%%.*}"
    archive="$out/freebsd-input/$release.tar"
    repo_files input "$major" "freebsd-input/$release.tar"
    freebsd_run "$release" "$job" "$out/freebsd" "$archive"
    # Removed before the result is looked at, so that a failed run leaves no key file either.
    repo_files remove-input "freebsd-input/$release.tar"
    [ "$run_status" -eq 0 ] || fail "FreeBSD $release failed"
    check_packages "$major"
    repo_files merge
    echo "ok   FreeBSD $release"
}

freebsd_each_release build_and_test
ls "$out"/freebsd/*/*.pkg "$published"/*/meta.conf
