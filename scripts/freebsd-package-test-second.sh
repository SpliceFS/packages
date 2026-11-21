#!/bin/sh
# check-not-run: runs inside the FreeBSD machine at its second boot, from the one-shot rc.d script that scripts/freebsd-package-test-job.sh installed
# The second boot of the package test on FreeBSD: phases 2 and 3 of the steps
# (scripts/package-test-steps.sh), after the machine restarted, which is the restart of step 5. It is
# run by the one-shot rc.d script of the image with the result folder as its only argument.
set -eu

state="${PACKAGE_TEST_ROOT:-}/var/tmp/package-test"
# shellcheck source=freebsd-package-test-lib.sh
. "$state/input/src/scripts/freebsd-package-test-lib.sh"
run_and_return_results "$1" phase2 phase3
