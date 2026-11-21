# shellcheck shell=sh
# What the steps of scripts/package-test-steps.sh look at in the system they install our packages in:
# the checks of scripts/package-test-lib.sh, no process of ours, the packages the package manager
# holds, the snapshot of the files, and the core dumps. Every command goes through on_system
# (scripts/service-run-local.sh: it runs right here, inside the system), with the repository as the
# current folder. Sourced after scripts/package-lib.sh, which provides fail. The first argument of
# each is the name of the system; $own is the folder of the run's files, as the caller sets it.
# shellcheck disable=SC2154

# Runs the package checks of scripts/package-test-lib.sh, which look at the system they run in,
# in the system $1: the checks named by the other arguments, for the program and version of the
# caller, in a shell of their own, so that the fail of a check ends the checks and not the steps. A
# program that has a test configuration (programs/PROGRAM/test-config.sh) gets its functions too,
# so that the same call writes it, checks it and removes what it made. The address of the system, which
# the adapter of the package format knows, goes with it in OWN_ADDRESS, for the test configuration that
# names the server of the system by it.
in_system() {
    system_name="$1"
    shift
    system_address="$(own_address)"
    # The script is for the shell that sh -c starts, which reads its own variables.
    # shellcheck disable=SC2016
    on_system "$system_name" env OWN_ADDRESS="$system_address" sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh
        if [ -f "$defs/test-config.sh" ]; then . "$defs/test-config.sh"; fi
        for check in "$@"; do "$check"; done' sh "$@"
}

# Nothing of ours runs: no process has one of our files as its program, also not one that was started from a
# file that is gone now. The pattern $2 (a path with a glob, the program of the service by default every
# program of ours) says whose; a service that stopped leaves the other programs running. /proc is what
# every system has.
no_process_of_ours() {
    # The script is for the shell that sh -c starts, which reads its own variables.
    # shellcheck disable=SC2016
    on_system "$1" sh -c '
        for dir in /proc/[0-9]*; do
            case "$(readlink "$dir/exe" 2>/dev/null)" in
                $1) exit 1 ;;
                *) ;;
            esac
        done' sh "${2:-*/splicefs*}"
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
        if on_system "$1" sh -c '. scripts/package-lib.sh; . scripts/package-held-lib.sh; package_held "$@"' \
            sh "$format" "$held_name"; then
            held_list="$held_list${held_list:+ }$held_name"
        fi
    done
    echo "$held_list"
}

# Writes the snapshot of the system $1 into the file $2.
take_snapshot() {
    on_system "$1" sh scripts/lifecycle-snapshot.sh >"$2" || fail "the snapshot of the system failed"
}

# Prints the core dumps that appeared in the system $1 since the last call, with what ran before
# them ($2), so that a crash in any step names its program and its step (scripts/core-files.sh).
# They are also kept in $own/cores-noted, for the comparison of the snapshots to name them again
# next to the difference. The first call has nothing to compare with: $own/cores-seen starts empty.
note_new_cores() {
    on_system "$1" sh scripts/core-files.sh >"$own/cores-now" || fail "looking for core dumps failed"
    grep -vxFf "$own/cores-seen" "$own/cores-now" | sed "s/^/core dump after $2: /" | tee -a "$own/cores-noted" || true
    mv "$own/cores-now" "$own/cores-seen"
}

# Prints, for every path of a core in the difference $2 of the snapshots, the core dump as a step
# noted it, or else what the file in the system $1 is now: a core can be incomplete when it is looked
# at, because the host's handler writes it while the system runs on. A path starts with a slash,
# which a line of checksums does not.
name_cores_in_difference() {
    sed -n 's|^[<>] \(/.*core[^/]*\)$|\1|p' "$2" >"$own/core-paths"
    while IFS= read -r core_path; do
        grep -F ": $core_path pid " "$own/cores-noted" && continue
        on_system "$1" sh scripts/core-files.sh "$core_path" >"$own/core-read" || fail "looking at $core_path failed"
        sed "s/^/core dump no step could read: /" "$own/core-read"
    done <"$own/core-paths"
}

# Runs the functions of scripts/upgrade-lib.sh (write_markers, verify_markers_kept) in the system
# $1 with the arguments after it, for the program, version and published version of the caller, in a
# shell of their own like in_system. The configuration file and the data file they write are what a
# removal or an upgrade must leave alone.
in_upgrade_lib() {
    system_name="$1"
    shift
    on_system "$system_name" sh -c '. scripts/upgrade-lib.sh; "$@"' sh "$@"
}
