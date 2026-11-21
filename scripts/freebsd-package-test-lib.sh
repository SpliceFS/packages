# shellcheck shell=sh
# Sourced by the two parts of the package test that run inside the FreeBSD machine: the first-boot job
# (scripts/freebsd-package-test-job.sh) and the file of the second boot
# (scripts/freebsd-package-test-second.sh). The machine has no channel to the host while it runs,
# so the host starts it twice and what the steps wrote stays on the system disk between the boots.
# PACKAGE_TEST_ROOT puts every path below a folder, for the test of these scripts.

root_dir="${PACKAGE_TEST_ROOT:-}"
# The folder that scripts/lifecycle-excluded leaves out of the snapshots: the input of the host, the
# environment of the steps and their output.
state="$root_dir/var/tmp/package-test"

# The environment the steps need (scripts/package-test-steps.sh), written once by the first boot so
# that the second boot has the same. Usage: write_package_test_env PROGRAM...
write_package_test_env() {
    cat >"$state/env" <<ENV
FORMAT=pkg
PLATFORM=freebsd/amd64
PROGRAMS="$*"
PACKAGE_TEST_OUT=$state/out
BASELINES=$state/input/baselines
PACKAGE_FILES=$state/input/pkg
ENV
}

# Runs the phases named by the arguments, in order, and stops at the first that fails. The status is
# that of the phase that failed.
run_package_test_phases() {
    for phase in "$@"; do
        phase_status=0
        (
            # shellcheck source=/dev/null
            . "$state/env"
            export FORMAT PLATFORM PROGRAMS PACKAGE_TEST_OUT BASELINES PACKAGE_FILES
            sh "$state/input/src/scripts/package-test-steps.sh" "$phase"
        ) || phase_status=$?
        [ "$phase_status" -eq 0 ] || return "$phase_status"
    done
}

# Prints the step the steps stopped in, with every line from its last line on: what it printed and why
# it failed. Prints nothing when the steps wrote no result.
show_failed_step() {
    [ -f "$state/out/result" ] || return 0
    read -r failed_line <"$state/out/result"
    echo "$failed_line"
    [ -f "$state/out/log" ] || return 0
    awk -v line="$failed_line" '
        { text[NR] = $0 }
        $0 == line { found = NR }
        END { if (found == 0) found = 1; for (i = found; i <= NR; i++) print text[i] }
    ' "$state/out/log"
}

# Runs the phases the arguments name and writes what the host reads into the result folder $1: the
# output folder of the steps. What the phases printed is shown, and when one fails the step it failed in.
# The status is that of the phases. Usage: run_and_return_results RESULT_FOLDER PHASE...
run_and_return_results() {
    results="$1"
    shift
    mkdir -p "$state/out"
    printed="$(wc -l <"$state/out/log" 2>/dev/null || echo 0)"
    run_status=0
    run_package_test_phases "$@" || run_status=$?
    tail -n +"$((printed + 1))" "$state/out/log"
    if [ "$run_status" -ne 0 ]; then
        echo "--- the step that failed"
        show_failed_step
    fi
    rm -rf "$results/package-test"
    cp -R "$state/out" "$results/package-test"
    return "$run_status"
}
