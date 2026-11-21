#!/bin/sh
# check: freebsd-package-test-job.sh: the first boot runs phase 1 and prepares the second, which runs phases 2 and 3; a failed step is printed
# Test of scripts/freebsd-package-test-job.sh, scripts/freebsd-package-test-second.sh and
# scripts/freebsd-package-test-lib.sh on a folder that stands in for the root of the machine
# (PACKAGE_TEST_ROOT) and a file that stands in for the input disk (PACKAGE_TEST_INPUT), so the test
# needs no FreeBSD and runs in milliseconds (part of make check). The steps are a stand-in that logs
# the phase it was given and fails the phase named in FAIL_PHASE with a step line.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failed=0

# The input the host makes: the library of the repository and a stand-in for the steps.
mkdir -p "$t/input/src/scripts"
cp "$root/scripts/freebsd-package-test-lib.sh" "$t/input/src/scripts/"
cat >"$t/input/src/scripts/package-test-steps.sh" <<'STAND_IN'
#!/bin/sh
# The stand-in of the steps: what the real ones do with their output folder, with one step line a phase.
own="$PACKAGE_TEST_OUT"
mkdir -p "$own"
exec >>"$own/log" 2>&1
echo "step for $1: $PROGRAMS $FORMAT $PLATFORM $BASELINES $PACKAGE_FILES"
echo "step for $1" >"$own/step-line"
if [ "${FAIL_PHASE:-}" = "$1" ]; then
    echo "the check that failed"
    cat "$own/step-line" >"$own/result"
    exit 1
fi
echo ok >"$own/result"
STAND_IN
tar -cf "$t/input.tar" -C "$t/input" .
mkdir -p "$t/jobfolder"
cp "$root/scripts/freebsd-package-test-second.sh" "$t/jobfolder/"
# The template of the image, as far as the job reads it.
cat >"$t/jobfolder/second-boot.in" <<'TEMPLATE'
#!/bin/sh
#
# PROVIDE: second_boot
# REQUIRE: LOGIN
# KEYWORD: nojail
run @FILE@
TEMPLATE

same() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

# $1 the folder of the case: its machine root and its results. Runs the first boot with the phase
# FAIL_PHASE failing, when it is set, and puts its output in $1/said.
first_boot() {
    rm -rf "$1"
    mkdir -p "$1/machine" "$1/results"
    status=0
    PACKAGE_TEST_ROOT="$1/machine" PACKAGE_TEST_INPUT="$t/input.tar" \
        sh "$root/scripts/freebsd-package-test-job.sh" "$t/jobfolder" "$1/results" server client >"$1/said" 2>&1 || status=$?
    first_status="$status"
}

first_boot "$t/good"
same "the first boot passes" 0 "$first_status"
grep -q "^step for phase1: server client pkg freebsd/amd64 " "$t/good/said" && found=yes || found=no
same "the first boot runs phase 1 for the programs, the format and the platform of FreeBSD, with the input where it unpacked" yes "$found"
grep -q "phase2\|phase3" "$t/good/said" && found=yes || found=no
same "the first boot runs no later phase" no "$found"
second="$t/good/machine/usr/local/etc/rc.d/second_boot"
[ -x "$second" ] && found=yes || found=no
same "the one-shot script is installed and may run" yes "$found"
same "it requires the services of both programs, as decided" "# REQUIRE: LOGIN splicefsd splicefs" "$(grep '^# REQUIRE' "$second")"
same "it runs the file of the second boot, which is on the system disk" "run /var/db/second-boot/phase-two.sh" "$(grep '^run' "$second")"
[ -f "$t/good/machine/var/db/second-boot/phase-two.sh" ] && found=yes || found=no
same "the file of the second boot is there" yes "$found"
[ -f "$t/good/results/second-boot" ] && found=yes || found=no
same "the second boot is asked for" yes "$found"
same "the result of the steps goes back to the host" ok "$(cat "$t/good/results/package-test/result")"

# The second boot: the machine restarted, the results of the first boot are restored in the result folder.
status=0
PACKAGE_TEST_ROOT="$t/good/machine" sh "$root/scripts/freebsd-package-test-second.sh" "$t/good/results" >"$t/good/second-said" 2>&1 || status=$?
same "the second boot passes" 0 "$status"
grep -q "^step for phase2" "$t/good/second-said" && grep -q "^step for phase3" "$t/good/second-said" && found=yes || found=no
same "the second boot runs phase 2 and then phase 3" yes "$found"
same "it shows only what its own phases printed" 0 "$(grep -c "^step for phase1" "$t/good/second-said" || true)"
same "the log that goes back holds the phases of both boots" 3 "$(grep -c '^step for' "$t/good/results/package-test/log")"

FAIL_PHASE=phase1 first_boot "$t/bad1"
same "a first boot whose phase 1 fails fails" 1 "$first_status"
grep -q "^the check that failed" "$t/bad1/said" && found=yes || found=no
same "it prints the step that failed, with the lines from it" yes "$found"
[ ! -e "$t/bad1/results/second-boot" ] && [ ! -e "$t/bad1/machine/usr/local/etc/rc.d/second_boot" ] && found=none || found=some
same "a failed first boot asks for no second boot and leaves no one-shot script" none "$found"
same "the failed step goes back to the host" "step for phase1" "$(cat "$t/bad1/results/package-test/result")"

# A failure in phase 3 after phase 2 passed: the second boot fails and names the step.
status=0
FAIL_PHASE=phase3 PACKAGE_TEST_ROOT="$t/good/machine" sh "$root/scripts/freebsd-package-test-second.sh" "$t/good/results" \
    >"$t/good/second-bad" 2>&1 || status=$?
same "a second boot whose phase 3 fails fails" 1 "$status"
grep -q "^step for phase3$" "$t/good/second-bad" && grep -q "^the check that failed" "$t/good/second-bad" && found=yes || found=no
same "it prints the step that failed and its lines" yes "$found"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "freebsd package test job: all cases as expected"
