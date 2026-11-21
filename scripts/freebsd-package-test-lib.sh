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

# Sets PATH to the one a root login gets on FreeBSD: the path capability of the default class of
# /etc/login.conf as the image ships it (the root class takes it from default), with ~/bin as the
# /root/bin of root. The machine starts the job and the one-shot script from rc, whose path has no
# /usr/local, where the packages put their programs; the steps look for the programs as a root user does.
set_root_login_path() {
    PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/root/bin
    export PATH
}

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

# Prints the lines of the log after its first $1 lines, the ones of the phases that ran before, for a
# phase that failed: the line "--- the step that failed" comes before the step the result names, so
# that the step and what it printed are on the screen once, after that line. A result that names no
# line of the log, or none at all, puts the line after everything.
show_failed_phase_lines() {
    [ -f "$state/out/log" ] || return 0
    failed_line=""
    [ ! -f "$state/out/result" ] || read -r failed_line <"$state/out/result"
    awk -v skip="$1" -v line="$failed_line" '
        NR > skip { text[++count] = $0; if (line != "" && $0 == line) found = count }
        END {
            if (found == 0) found = count + 1
            for (i = 1; i <= count; i++) {
                if (i == found) print "--- the step that failed"
                print text[i]
            }
            if (found == count + 1) print "--- the step that failed"
        }
    ' "$state/out/log"
}

# Runs the phases the arguments name and writes what the host reads into the result folder $1: the
# output folder of the steps. What the phases printed is shown, and when one fails the step it failed in
# is set apart (show_failed_phase_lines).
# The status is that of the phases. Usage: run_and_return_results RESULT_FOLDER PHASE...
run_and_return_results() {
    results="$1"
    shift
    mkdir -p "$state/out"
    # The redirection of a missing file fails in the shell itself, which says so before 2>/dev/null applies.
    printed=0
    [ ! -f "$state/out/log" ] || printed="$(wc -l <"$state/out/log")"
    run_status=0
    run_package_test_phases "$@" || run_status=$?
    if [ "$run_status" -eq 0 ]; then
        tail -n +"$((printed + 1))" "$state/out/log"
    else
        show_failed_phase_lines "$printed"
    fi
    rm -rf "$results/package-test"
    cp -R "$state/out" "$results/package-test"
    return "$run_status"
}
