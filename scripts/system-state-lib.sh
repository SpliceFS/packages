# shellcheck shell=sh
# What the tests that boot a system and install our packages in it (scripts/package-test.sh) look at on the host: the checks of scripts/package-test-lib.sh run
# inside the container, no process of ours, the snapshot of the files, and the core dumps. Sourced
# after scripts/package-lib.sh, which provides fail. The first argument of each is the container;
# $own is the folder of the system's files, as the caller sets it.
# shellcheck disable=SC2154

# Runs the package checks of scripts/package-test-lib.sh, which look at the system they run in,
# inside the container $1: the checks named by the other arguments, for the program and version
# of the caller. The repository is mounted at /src, where those scripts read their definitions. A
# program that has a test configuration (programs/PROGRAM/test-config.sh) gets its functions too,
# so that the same call writes it, checks it and removes what it made.
in_system() {
    container_name="$1"
    shift
    docker exec -e PROGRAM -e VERSION -e PACKAGE_DATE -w /src "$container_name" sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh
        if [ -f "$defs/test-config.sh" ]; then . "$defs/test-config.sh"; fi
        for check in "$@"; do "$check"; done' sh "$@"
}

# Nothing of our programs runs: no process has one of their files as its program, also not one
# that was started from a file that is gone now. /proc is what every system has.
no_process_of_ours() {
    docker exec "$1" sh -c '
        for dir in /proc/[0-9]*; do
            case "$(readlink "$dir/exe" 2>/dev/null)" in
                */splicefs*) exit 1 ;;
                *) ;;
            esac
        done'
}

# Prints the package names of our programs that the package manager of the system $1 still holds
# (scripts/package-held-lib.sh decides, for the format of the caller), separated by spaces. The names
# are those of programs/*/program.conf.
held_packages() {
    held_list=""
    for held_conf in programs/*/program.conf; do
        held_name="$(sed -n 's/^name=//p' "$held_conf")"
        # package_held is one test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        if docker exec -e PROGRAM -e VERSION -e PACKAGE_DATE -w /src "$1" sh -c '. scripts/package-lib.sh; . scripts/package-held-lib.sh; package_held "$@"' \
            sh "$format" "$held_name"; then
            held_list="$held_list${held_list:+ }$held_name"
        fi
    done
    echo "$held_list"
}

# Writes the snapshot of the system into the file $2 on the host.
take_snapshot() {
    docker exec "$1" sh /src/scripts/lifecycle-snapshot.sh >"$2" || fail "the snapshot of the system failed"
}

# Prints the core dumps that appeared in the system $1 since the last call, with what ran before
# them ($2), so that a crash in any step names its program and its step (scripts/core-files.sh).
# The comparison of the snapshots finds a core on the root filesystem anyway; this says where it
# came from. The first call has nothing to compare with: $own/cores-seen starts empty.
note_new_cores() {
    docker exec "$1" sh /src/scripts/core-files.sh >"$own/cores-now" || fail "looking for core dumps failed"
    grep -vxFf "$own/cores-seen" "$own/cores-now" | sed "s/^/core dump after $2: /" || true
    mv "$own/cores-now" "$own/cores-seen"
}

# Runs the functions of scripts/upgrade-lib.sh (write_markers, verify_markers_kept) inside the
# container $1 with the arguments after it, for the program, version and published version of the
# caller. The configuration file and the data file they write are what a removal or an upgrade
# must leave alone.
in_upgrade_lib() {
    container_name="$1"
    shift
    docker exec -e PROGRAM -e VERSION -e PACKAGE_DATE -e PUBLISHED_VERSION -w /src "$container_name" sh -c \
        '. scripts/upgrade-lib.sh; "$@"' sh "$@"
}
