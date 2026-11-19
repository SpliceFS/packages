#!/bin/sh
# Prints where the install tests (tests/run.sh, tests/freebsd.sh) take the setup script and the
# packages from, for the test groups of a run (scripts/changed-groups.sh, .github/test-groups):
#   built      the group packages is among them: the packaging changed, or the run tests
#              everything (main, the schedule). The packages are built from the branch.
#   published  it is not: nothing that is packaged changed, so the setup script is run against the
#              published site, with its real keys and its published packages, and nothing is built.
# The words are those of SOURCE in the Makefile (scripts/published-site-lib.sh).
# Usage: install-source.sh '["install","packages"]'
set -eu

packaging_group=packages

case "${1:-}" in
    '['*']') ;;
    *)
        echo 'usage: install-source.sh GROUPS, a JSON array of the groups, for example ["install"]' >&2
        exit 2
        ;;
esac

case "$1" in
    *\"$packaging_group\"*) echo built ;;
    *) echo published ;;
esac
