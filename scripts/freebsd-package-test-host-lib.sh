# shellcheck shell=sh
# Sourced by scripts/freebsd-package-test.sh, the host's part of the package test on FreeBSD, after
# scripts/package-test-program-lib.sh and scripts/freebsd-lib.sh: what the host puts on the disks of
# the machine. The machine has no mount of the host, so the job folder is its first disk and the input
# archive its fourth. The caller sets root (the repository), work (a folder of its own), baselines
# (see scripts/package-test-program-lib.sh) and defines fail.
# shellcheck disable=SC2154 # the caller sets those variables, scripts/package-lib.sh the rest

# Prints the package file of the program $1 for the release major version $2, or nothing.
package_of() {
    # A program that was not built has no record of its build, which use_program refuses.
    [ -f "dist/$1/version" ] || return 0
    use_program "$1"
    candidate="dist/$1/freebsd/FreeBSD-$2-amd64/$name-$pkgver.pkg"
    [ ! -f "$candidate" ] || echo "$candidate"
}

# Writes the input archive of the machine, $2, for the programs named by the other arguments and the
# release major version $1: the repository files the steps read (setup.sh.in is the setup script's text,
# which the repository file of the test is taken from), the package files, and the version of each
# baseline. The Mac's own attributes are left out: FreeBSD's tar reports them as errors.
make_input() {
    major="$1"
    archive="$2"
    shift 2
    stage="$work/input-$major"
    rm -rf "$stage"
    mkdir -p "$stage/src/dist" "$stage/pkg" "$stage/baselines"
    for copied in scripts programs steps keys packaging setup.sh.in; do
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

# Makes the job folder $2 of the release $1 for the programs named by the other arguments: the job of
# the first boot, the file of the second boot and the template of its one-shot script, which the image
# of the machine provides.
make_job_folder() {
    release="$1"
    job="$2"
    shift 2
    freebsd_job_folder "$release" "$job" scripts/freebsd-package-test-job.sh "$@"
    cp scripts/freebsd-package-test-second.sh "$job/"
    machine_image="$(freebsd_image "$release")"
    docker run --rm "$machine_image" cat /freebsd/second-boot.in >"$job/second-boot.in" ||
        fail "cannot read /freebsd/second-boot.in from $machine_image: the image is too old for a second boot"
}
