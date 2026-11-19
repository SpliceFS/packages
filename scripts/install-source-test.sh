#!/bin/sh
# check: install-source.sh: the install tests use the published site unless the packaging changed, or the run tests everything
# Test of scripts/install-source.sh (part of make check): the choice between the published site and
# the packages the branch builds, from the test groups of a run. The cases with real paths run
# scripts/changed-groups.sh on the real .github/test-groups first, so a group that is renamed
# there cannot turn every run into one against the published site without a word. Runs on the host.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/install-source.sh"
failed=0

# $1 case name, $2 the word wanted, $3 the groups.
choice() {
    got="$(sh "$script" "$3")" || got="exit status $?"
    if [ "$got" = "$2" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: wanted %s got %s\n' "$1" "$2" "$got"
        failed=$((failed + 1))
    fi
}

# $1 case name, $2 the changed paths, one per line, $3 the word wanted.
from_paths() {
    choice "$1" "$3" "$(printf '%s' "$2" | sh "$root/scripts/changed-groups.sh")"
}

choice "the install tests alone" published '["install"]'
choice "the packages group" built '["packages"]'
choice "both groups" built '["install","packages"]'
choice "no group" published '[]'
choice "a group that only starts with the word" published '["install","packages-extra"]'
choice "a group that only ends with the word" published '["install","all-packages"]'

from_paths "a change to the install tests alone" 'tests/run.sh
tests/systems
' published
from_paths "a change to a script is packaging" 'scripts/package-lib.sh
' built
from_paths "a change to a program is packaging" 'programs/server/program.conf
' built
from_paths "a change to the setup script template is packaging" 'setup.sh.in
' built
from_paths "a change to the install tests and a package definition" 'tests/run.sh
packaging/test-systems
' built
choice "a run that tests everything (main, the schedule)" built "$(sh "$root/scripts/changed-groups.sh" all)"

# The words the script prints are the words the tests that read SOURCE accept.
# shellcheck source=published-site-lib.sh
. "$root/scripts/published-site-lib.sh"
for word in built published; do
    if (SOURCE="$word" check_install_source) >/dev/null 2>&1; then
        printf 'ok   check_install_source accepts %s\n' "$word"
    else
        printf 'FAIL check_install_source refuses %s, which install-source.sh prints\n' "$word"
        failed=$((failed + 1))
    fi
done

# $1 case name, $2 the arguments.
refused() {
    # shellcheck disable=SC2086 # the arguments are words on purpose
    if sh "$script" $2 >/dev/null 2>&1; then
        printf 'FAIL %s: not refused\n' "$1"
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}
refused "no argument is refused" ''
refused "words that are no JSON array are refused" 'install,packages'
refused "a word alone is refused" 'packages'

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "install-source checks done"
