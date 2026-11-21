#!/bin/sh
# check: package-test-lib.sh: the version checks, also for a package published before a program was added
# Test of the version checks of scripts/package-test-lib.sh. They run inside a system a package is
# installed in; here the system is a folder of fake programs on the PATH, so the test needs no
# Docker (part of make check).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# Puts a program named $1 that reports the version $2 in the folder $3.
program_reporting() {
    printf '#!/bin/sh\necho "%s %s"\n' "$1" "$2" > "$3/$1"
    chmod 755 "$3/$1"
}

# $1 case name, $2 the check, $3 the folder of fake programs, $4 what it must answer: ok, or the
# text of its refusal.
runs() {
    got="$(PATH="$3:$PATH" PROGRAM=server VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh; "$1"' sh "$2" 2>&1)" && status=ok || status="$got"
    case "$status" in
        *"$4"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted "%s" got "%s"\n' "$1" "$4" "$status"
            failed=$((failed + 1))
            ;;
    esac
}

# A system the newest release is installed in, and one a package from before splicefsdctl was
# shipped is installed in.
mkdir "$work/new" "$work/old" "$work/stale"
for each in splicefsd splicefsdctl; do program_reporting "$each" v1.2.3 "$work/new"; done
program_reporting splicefsd v1.2.3 "$work/old"
program_reporting splicefsd v1.2.2 "$work/stale"

runs "every program of the new package reports the version" check_versions "$work/new" ok
runs "a program of program.conf that is not installed is found" check_versions "$work/old" "splicefsdctl"
runs "the published package is judged by its service program alone" check_service_version "$work/old" ok
runs "the service program of the published package must report its version" check_service_version "$work/stale" \
    "splicefsd --version does not report v1.2.3"

# The removal check looks in the program folder of the table of the format, not in a folder written
# in the check: the folder of the table is replaced by a fake one, once with a program left in it.
# $1 case name, $2 the folder, $3 what it must answer: ok, or the text of its refusal.
removal_runs() {
    got="$(FORMAT=pkg PROGRAM=server VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh; bindir="$1"; check_programs_removed' sh "$2" 2>&1)" &&
        status=ok || status="$got"
    case "$status" in
        *"$3"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted "%s" got "%s"\n' "$1" "$3" "$status"
            failed=$((failed + 1))
            ;;
    esac
}

mkdir "$work/gone" "$work/left"
: > "$work/left/splicefsdctl"
removal_runs "a removal that left no program in the program folder of the format passes" "$work/gone" ok
removal_runs "a program left in the program folder of the format is found" "$work/left" "remove left splicefsdctl behind"

if [ "$failed" -ne 0 ]; then
    echo "$failed package-test-lib case(s) failed"
    exit 1
fi
echo "package-test-lib: all cases as expected"
