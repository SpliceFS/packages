# shellcheck shell=sh
# Runs one test per system, every system at the same time, so a run takes as long as its slowest
# system instead of the sum of them. Sourced by the tests that boot one container per system.

# Reads lines "FORMAT IMAGE" from standard input; blank lines are skipped. First it runs PREPARE FORMAT IMAGE for every
# line, one after another (pulling an image, which must happen once and before anything starts);
# then it starts TEST FORMAT IMAGE NUMBER for every prepared line at once, NUMBER being the line's
# place in the list, which a test uses to name what must differ between systems (a container, a
# folder). A system whose PREPARE fails is a failed system and does not start. Each system's
# output goes to a file of its own, and the outputs are printed in the order of the list once that
# system's process has ended, so they are never mixed. Order comes from waiting on each process.
# Prints the counts and the names of the failed systems; status 1 when any failed.
# Usage: run_systems FOLDER PREPARE TEST <LIST
# FOLDER is an empty folder the caller removes. It is also where stop_systems looks for the systems
# still running, so the caller calls stop_systems before it removes the folder.
run_systems() {
    start_systems "$@"
    report_systems "$out" "$count"
}

# The first half of run_systems: prepares every system, then starts the prepared ones, and returns
# without waiting for them. It sets out (FOLDER) and count (the number of lines of the list) for
# report_systems. A caller that wants to stop the systems before they end calls stop_systems
# between the two. Usage: start_systems FOLDER PREPARE TEST <LIST
start_systems() {
    out="$1"
    systems_folder="$1"
    prepare="$2"
    test="$3"
    count=0
    while read -r format image; do
        [ -n "$format" ] || continue
        count=$((count + 1))
        echo "$format $image" >"$out/$count.name"
        # PREPARE's status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        if "$prepare" "$format" "$image" >"$out/$count.out" 2>&1; then
            : >"$out/$count.ready"
        fi
    done
    each=0
    while [ "$each" -lt "$count" ]; do
        each=$((each + 1))
        [ -f "$out/$each.ready" ] || continue
        read -r format image <"$out/$each.name"
        "$test" "$format" "$image" "$each" >>"$out/$each.out" 2>&1 &
        echo "$!" >"$out/$each.pid"
    done
}

# Waits for each system's process in the order of the list and prints its output, then the
# counts, then one line "failed system: FORMAT IMAGE" per failed system: a CI log merges standard
# output and standard error line by line, so a name on a line of its own under a heading can end
# up below another program's message. Usage: report_systems FOLDER COUNT
report_systems() {
    passed=0
    failed=0
    : >"$1/failed"
    each=0
    while [ "$each" -lt "$2" ]; do
        each=$((each + 1))
        status=1
        pid=""
        if [ -f "$1/$each.pid" ]; then read -r pid <"$1/$each.pid"; fi
        if [ -n "$pid" ] && wait "$pid"; then status=0; fi
        cat "$1/$each.out"
        if [ "$status" -eq 0 ]; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            read -r name <"$1/$each.name"
            echo "failed system: $name" >>"$1/failed"
        fi
    done
    echo "passed: $passed  failed: $failed"
    cat "$1/failed"
    [ "$failed" -eq 0 ]
}

# The PREPARE of the tests that boot an image: pulls it for the platform $platform of the caller
# (pull_image of scripts/package-lib.sh). A registry failure must not look like a failed test, so
# it says so. Usage: pull_system FORMAT IMAGE.
pull_system() {
    # pull_image checks every command itself; its status is the answer. platform is the caller's.
    # shellcheck disable=SC2154,SC2310
    pull_image "$platform" "$2" && return 0
    echo "FAIL $1 $2"
    echo "     could not download the image $2 (3 tries)"
    return 1
}

# Ends the processes of the systems that are still running, for a run that is being stopped (its
# time limit, Ctrl-C): the caller's cleanup calls it before it removes the containers. It reads the
# shell's own list of background jobs, which already holds a system the moment it is started, and
# not a list kept here: a stop that arrives between starting a system and noting its process id
# would miss that system and leave it running. The list goes through a file because dash gives a
# command substitution an empty one. Every background job of the caller is a system.
# A caller calls it from its trap for INT, TERM or EXIT. Open defect: bash 3.2 (the macOS /bin/sh)
# can lose a TERM that arrives just before its wait builtin blocks, so the trap never runs and the
# systems keep running. It was seen only on bash 3.2; dash does not lose the signal.
stop_systems() {
    [ -n "${systems_folder:-}" ] || return 0
    jobs -p >"$systems_folder/jobs" || return 0
    while read -r pid; do
        kill "$pid" 2>/dev/null || true
    done <"$systems_folder/jobs"
}
