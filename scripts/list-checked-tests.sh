#!/bin/sh
# check: list-checked-tests.sh: every *-test.sh says whether make check runs it, and none is left out
# Prints the test scripts that make check runs, one a line: the path, a space, and the description
# the script gives on its second line ("# check: DESCRIPTION"), which is the name its result has
# in the output of check.sh. A script that says "# check-not-run: REASON" there is not listed: it
# needs Docker, the network or built packages, and CI runs it through its own make target.
# Usage: list-checked-tests.sh    (from any folder; the scripts are found in the whole repository)
#
# Why the scripts say it themselves: a list of tests in check.sh is edited by every change that
# adds a test, so the open changes conflict there again and again, and a test that was added to
# the folder but not to the list is never run. A script that says neither of the two things is
# an error that names it, so a test cannot exist without being run or without saying why not.
# The listing is still printed in full, so that the tests that can run do.
set -eu

cd "$(dirname "$0")/.."
tests="$(find . \( -name .git -o -name dist \) -prune -o -type f -name '*-test.sh' -print |
    sed 's|^\./||' | LC_ALL=C sort)"
[ -n "$tests" ] || { echo "FAIL: no *-test.sh script found" >&2; exit 1; }

status=0
while IFS= read -r file; do
    line="$(sed -n 2p "$file")"
    case "$line" in
        "# check: "?*) printf '%s %s\n' "$file" "${line#'# check: '}" ;;
        "# check-not-run: "?*) ;;
        *)
            echo "FAIL: line 2 of $file is neither '# check: DESCRIPTION' nor '# check-not-run: REASON'" >&2
            status=1
            ;;
    esac
done <<EOF
$tests
EOF
exit "$status"
