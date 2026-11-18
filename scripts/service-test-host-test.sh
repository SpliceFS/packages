#!/bin/sh
# Test of the parts of scripts/service-test-host.sh that run on any computer (part of make check):
# the script refuses to run anywhere but in CI, before it touches anything, and the way each program
# asks "does the service work" on the machine itself (answers_here of programs/*/service-check.sh)
# tells a working service from a broken one. The commands the checks run (curl, sudo, splicefsctl,
# apt-get) are stand-ins in a folder at the front of PATH, so nothing is installed or started.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
mkdir "$work/bin"

# Every stand-in writes its name and arguments to the file "calls". curl prints the status code
# in FAKE_CODE, as the real one does for -w '%{http_code}'. sudo runs the command that follows,
# so the stand-in of the client's control command decides, with the status in FAKE_STATUS.
# The dollar signs are for the shell that runs the stand-in, not for this one.
# shellcheck disable=SC2016
for tool in apt-get systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$tool" "$work" > "$work/bin/$tool"
done
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "curl $*" >> "%s/calls"\nprintf "%%s" "$FAKE_CODE"\n' "$work" > "$work/bin/curl"
printf '#!/bin/sh\necho "sudo $*" >> "%s/calls"\n"$@"\n' "$work" > "$work/bin/sudo"
# shellcheck disable=SC2016
printf '#!/bin/sh\nexit "$FAKE_STATUS"\n' > "$work/bin/splicefsctl"
chmod 755 "$work"/bin/*

# $1 case name, $2 wanted status (0 or 1), then the command.
check() {
    case_name="$1"
    want="$2"
    shift 2
    status=0
    "$@" >"$work/out" 2>&1 || status=$?
    if [ "$status" -eq "$want" ]; then printf 'ok   %s\n' "$case_name"; else
        printf 'FAIL %s: want status %s, got %s\n' "$case_name" "$want" "$status"
        failed=$((failed + 1))
    fi
}

# Checks the output of the last run: $1 says what is checked, $2 is what must be in it.
said() {
    if grep -q -e "$2" "$work/out"; then printf 'ok   %s\n' "$1"; else
        printf 'FAIL %s\n' "$1"
        failed=$((failed + 1))
    fi
}

# Asks the program $1 the way it asks on the machine itself, when the health endpoint answers
# with the code $2 and the control command ends with the status $3.
answers_here() {
    # The command is for the shell that env starts, which reads $1 and $defs.
    # shellcheck disable=SC2016
    env PROGRAM="$1" FAKE_CODE="$2" FAKE_STATUS="$3" VERSION=v1.2.3 REVISION=0 PACKAGE_DATE=20261112 \
        PATH="$work/bin:$PATH" \
        sh -c 'cd "$1" && . scripts/package-lib.sh && . "$defs/service-check.sh" && answers_here' sh "$root"
}

: > "$work/calls"
for ci in "" false 1; do
    check "CI='$ci' is refused" 1 env CI="$ci" PROGRAM=server PATH="$work/bin:$PATH" sh "$root/scripts/service-test-host.sh"
    said "CI='$ci' says that it only runs in CI" "only runs in CI"
done
check "no CI variable is refused" 1 env -u CI PROGRAM=server PATH="$work/bin:$PATH" sh "$root/scripts/service-test-host.sh"
check "a refused run installs and starts nothing" 0 test ! -s "$work/calls"

check "the server answers when the health endpoint says 200" 0 answers_here server 200 1
: > "$work/calls"
check "the server does not answer when the health endpoint says 503" 1 answers_here server 503 0
check "the server does not answer when nothing answers" 1 answers_here server "" 0
check "the server is asked on its own port, on this machine" 0 grep -q -e 'https://127.0.0.1:8480/api/v1/health' "$work/calls"

: > "$work/calls"
check "the client answers when the status command succeeds" 0 answers_here client 500 0
check "the client does not answer when the status command fails" 1 answers_here client 200 1
check "the status command runs as root, which owns the control socket" 0 grep -q -e '^sudo splicefsctl status$' "$work/calls"

[ "$failed" -eq 0 ]
