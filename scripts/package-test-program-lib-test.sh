#!/bin/sh
# check: package-test-program-lib.sh: use_program chooses a program the same way for the host and for the steps, reading its baseline after the caller's hook
# Test of scripts/package-test-program-lib.sh, the one place that says what choosing a program for
# the package test sets: its version from the record of the build, the words of
# scripts/package-lib.sh and scripts/published-lib.sh, what its service check says, and its baseline,
# the version in a file of the folder $baselines. The host (scripts/package-test.sh) and the steps
# (scripts/package-test-steps.sh) both source it. Each case runs in a folder of its own with a record
# of a build, so it needs no Docker and no network.
# The dollar signs of the cases are the text of a script, not ours.
# shellcheck disable=SC2016
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failed=0

# The repository as the library sees it: the real scripts and definitions, and a record of a build
# of the server (v1.2.3, published 1.2.2).
mkdir -p "$t/root/dist/server" "$t/root/dist/client" "$t/baselines"
for each in scripts programs steps keys; do ln -s "$root/$each" "$t/root/$each"; done
printf 'VERSION=v1.2.3\nPACKAGE_DATE=20261112\nUPGRADE_FROM=1.2.2\n' >"$t/root/dist/server/version"
printf 'VERSION=v1.4.0\nPACKAGE_DATE=20261113\nUPGRADE_FROM=\n' >"$t/root/dist/client/version"
: >"$t/baselines/client"

# Runs the script $2 as the caller of use_program server, in the repository above, with the baseline
# file $1 ("none" for no file); prints what the script prints, and the status.
choose() {
    [ "$1" = none ] || printf '%s\n' "$1" >"$t/baselines/server"
    (
        cd "$t/root"
        platform=linux/amd64 baselines="$t/baselines" sh -c ". scripts/package-record.sh
. scripts/package-test-program-lib.sh
$2" 2>&1
    ) || echo "status $?"
    rm -f "$t/baselines/server"
}

# $1 case name, $2 what choose printed, $3 the text it must hold (a line, or part of one).
holds() {
    case "$2" in
        *"$3"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted [%s] in:\n%s\n' "$1" "$3" "$2"
            failed=$((failed + 1))
            ;;
    esac
}

got="$(choose 1.2.2 'use_program server; echo "$PROGRAM $VERSION $from $old_tag $PUBLISHED_VERSION $port $deb_arch"')"
holds "the program, its recorded version, its baseline, its service check and the CPU type are set" "$got" "server v1.2.3 1.2.2 v1.2.2 v1.2.2 8480 amd64"

got="$(choose '' 'use_program server; echo "[$from] $PUBLISHED_VERSION"')"
holds "an empty baseline file means nothing is published, and the published version is the new one" "$got" "[] v1.2.3"

got="$(choose 1.2.2 'use_program server; echo "$port"; use_program client; echo "[${port:-}]"')"
holds "what the service check of the program before set is not the next program's" "$got" "[]"

got="$(choose none 'prepare_baseline() { echo 1.2.2 >"$baselines/$PROGRAM"; }; use_program server; echo "$from"')"
holds "the hook of the caller runs before the baseline is read: it can make the file" "$got" "1.2.2"

got="$(choose 1.2.2 'prepare_baseline() { echo "hook sees $PROGRAM $VERSION $deb_arch"; }; use_program server')"
holds "the hook runs after the version and the words of the program are set" "$got" "hook sees server v1.2.3 amd64"

got="$(choose 1.2.2 'n=0; prepare_baseline() { n=$((n + 1)); }; use_program server; use_program server; use_program client; use_program server; echo "hook ran $n times"')"
holds "choosing the program that is chosen already does nothing, another program is chosen again" "$got" "hook ran 3 times"

# The baseline the host reads from the package site (save_baseline_version) is one function for every
# host. The site is not asked in these cases: upgrade_from_version is replaced inside the hook, which
# runs after the library sourced the real one.
got="$(choose none 'prepare_baseline() { save_baseline_version && echo "saved:$(cat "$baselines/$PROGRAM")"; }; use_program server; echo "from:$from"')"
holds "the baseline is read once into the file of the program, from the recorded version" "$got" "saved:1.2.2"

got="$(choose 1.2.0 'prepare_baseline() { upgrade_from_version() { return 1; }; save_baseline_version && echo "saved:$(cat "$baselines/$PROGRAM")"; }; use_program server')"
holds "a file that is there is kept, the site is not asked again" "$got" "saved:1.2.0"

got="$(choose none 'prepare_baseline() { upgrade_from_version() { :; }; save_baseline_version && echo "saved:[$(cat "$baselines/$PROGRAM")]"; }; use_program server')"
holds "nothing published makes an empty file" "$got" "saved:[]"

got="$(choose none 'prepare_baseline() { upgrade_from_version() { return 1; }; save_baseline_version; }; use_program server; echo "not reached"')"
holds "a site that cannot be read ends the caller and names the program and the site" "$got" "could not read the newest published package of server from https://packages.splicefs.org/server"
case "$got" in *"not reached"*) printf 'FAIL the caller went on after a site that cannot be read\n'; failed=$((failed + 1)) ;; *) ;; esac

got="$(choose 1.2.2 'given_version=v9.9.9; use_program server')"
holds "a version given by the caller must be the recorded one" "$got" "is not the recorded v1.2.3"

got="$(choose 1.2.2 'use_program ghost')"
holds "a program with no record ends the caller" "$got" "dist/ghost/version does not exist"

if [ "$failed" -ne 0 ]; then
    echo "$failed program-lib case(s) failed"
    exit 1
fi
echo "package-test-program-lib: all cases as expected"
