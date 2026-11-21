#!/bin/sh
# check-not-run: runs inside the FreeBSD machine as its first-boot job (scripts/freebsd-package-test.sh starts it)
# The first boot of the package test on FreeBSD: phase 1 of the steps (scripts/package-test-steps.sh),
# then it installs the one-shot rc.d script that runs phases 2 and 3 at the next boot
# (scripts/freebsd-package-test-second.sh) and asks for that boot. The machine runs as root, with
# the job folder and a result folder as the first two arguments, and the programs to test as the others.
# The input archive of the host is on the fourth disk: the repository, the package files and the
# versions of the published packages. The job folder holds second-boot.in, the template of the one-shot
# script, which the image of the machine provides, and the file of the second boot.
#   freebsd-package-test-job.sh <job folder> <result folder> PROGRAM...
set -eu

in="$1"
out="$2"
shift 2
root_dir="${PACKAGE_TEST_ROOT:-}"
input_device="${PACKAGE_TEST_INPUT:-/dev/vtbd3}"
state="$root_dir/var/tmp/package-test"

mkdir -p "$state/input" "$state/out"
tar -xf "$input_device" -C "$state/input" || { echo "FAIL: cannot read the input archive" >&2; exit 1; }
# shellcheck source=freebsd-package-test-lib.sh
. "$state/input/src/scripts/freebsd-package-test-lib.sh"
set_root_login_path
write_package_test_env "$@"
# The second boot runs after the services that the packages start: the one-shot script requires them,
# as the decision of the test says, and a service that is not installed is no requirement.
second_dir="$root_dir/var/db/second-boot"
mkdir -p "$second_dir" "$root_dir/usr/local/etc/rc.d"
cp "$in/freebsd-package-test-second.sh" "$second_dir/phase-two.sh"
sed -e "s|@FILE@|/var/db/second-boot/phase-two.sh|" -e 's|^# REQUIRE: LOGIN$|# REQUIRE: LOGIN splicefsd splicefs|' \
    "$in/second-boot.in" >"$root_dir/usr/local/etc/rc.d/second_boot"
chmod 555 "$root_dir/usr/local/etc/rc.d/second_boot"
# Asked for before the phase runs, so that the one-shot script is installed when the machine powers
# off, and removed when the phase failed: a failed first boot has no second.
touch "$out/second-boot"
status=0
# run_and_return_results is one command whose status is the answer, so set -e being off inside it changes nothing.
# shellcheck disable=SC2310
run_and_return_results "$out" phase1 || status=$?
if [ "$status" -ne 0 ]; then
    rm -f "$out/second-boot" "$root_dir/usr/local/etc/rc.d/second_boot"
fi
exit "$status"
