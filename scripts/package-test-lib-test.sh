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

# The client's own file checks look for the mount helper in the helper folder of the table of the
# format, not in a folder written in the check: the folder of the table is replaced by a fake one,
# holding a helper that behaves as the case says. $1 case name, $2 the helper folder, $3 what the
# checks must answer: ok, or the text of their refusal.
helper_runs() {
    got="$(FORMAT=pkg PROGRAM=client VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh; helperdir="$1"; check_extras' sh "$2" 2>&1)" &&
        status=ok || status="$got"
    case "$status" in
        *"$3"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted "%s" got "%s"\n' "$1" "$3" "$status"
            failed=$((failed + 1))
            ;;
    esac
}

# Puts a helper in the folder $1 that prints $2 and ends with status $3.
helper_saying() {
    mkdir "$1"
    printf '#!/bin/sh\necho "%s"\nexit %s\n' "$2" "$3" > "$1/mount.splicefs"
    chmod 755 "$1/mount.splicefs"
}

helper_saying "$work/helper-good" "usage: mount.splicefs cluster:/path folder" 1
helper_saying "$work/helper-succeeds" "usage: mount.splicefs cluster:/path folder" 0
helper_saying "$work/helper-silent" "nothing useful" 1
mkdir "$work/helper-none"
helper_runs "a mount helper in the helper folder of the format that prints its usage passes" "$work/helper-good" ok
helper_runs "a mount helper that is not in the helper folder of the format is found" "$work/helper-none" \
    "$work/helper-none/mount.splicefs is missing"
helper_runs "a mount helper that succeeds without arguments is found" "$work/helper-succeeds" \
    "mount.splicefs without arguments succeeded"
helper_runs "a mount helper that prints no usage is found" "$work/helper-silent" "mount.splicefs does not print its usage"

# The configuration folders are empty after an install, apart from the files the tests write as an
# administrator: the file of the upgrade test and the file of the test configuration of a program whose
# service runs before the upgrade. $1 case name, $2 the folder of the test configuration file that
# is made (or none), $3 the name test_config_file is set to (or empty), $4 what the check must answer: ok,
# or the text of its refusal.
config_cases=0
config_runs() {
    config_cases=$((config_cases + 1))
    config="$work/config-$config_cases"
    mkdir "$config"
    while IFS= read -r folder; do
        case "$folder" in "#"*) ;; *) mkdir "$config/$folder" ;; esac
    done <programs/server/config-folders
    if [ -n "$2" ]; then : >"$config/shares.d/$2"; fi
    got="$(FORMAT=pkg PROGRAM=server VERSION=v1.2.3 PACKAGE_DATE=20261112 test_config_file="$3" sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh; confdir="$1"; check_config_folders' sh "$config" 2>&1)" &&
        status=ok || status="$got"
    case "$status" in
        *"$4"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted "%s" got "%s"\n' "$1" "$4" "$status"
            failed=$((failed + 1))
            ;;
    esac
}

config_runs "empty configuration folders pass" "" "" ok
config_runs "a file the test configuration wrote passes when the program names it" media.yaml media.yaml ok
config_runs "a file in a configuration folder that no test wrote is found" media.yaml "" "shares.d must be empty after an install"
config_runs "another file than the one the program names is found" other.yaml media.yaml "shares.d must be empty after an install"

if [ "$failed" -ne 0 ]; then
    echo "$failed package-test-lib case(s) failed"
    exit 1
fi
echo "package-test-lib: all cases as expected"
