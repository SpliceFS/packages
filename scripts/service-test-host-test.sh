#!/bin/sh
# check: service-test-host.sh: refuses to run outside CI, and each program asks its service on the machine itself
# Test of the parts of scripts/service-test-host.sh that run on any computer (part of make check):
# the script refuses to run anywhere but in CI, before it touches anything, and the way each program
# asks "does the service work" on the machine itself (answers_here of programs/*/service-check.sh)
# tells a working service from a broken one, and which service commands of the machine need root. The commands the checks run (curl, sudo, splicefsctl,
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

# Runs the function $1 of the service functions of the machine for the server, as the checks do,
# with the name of the system they pass on as its argument.
service_here() {
    # The command is for the shell that env starts, which reads $1, $2 and its own variables.
    # shellcheck disable=SC2016
    env PROGRAM=server VERSION=v1.2.3 REVISION=0 PACKAGE_DATE=20261112 PATH="$work/bin:$PATH" \
        sh -c 'cd "$1" && . scripts/package-lib.sh && . scripts/service-test-host-deb.sh && "$2" host' sh "$root" "$1"
}

unit=splicefsd.service
: > "$work/calls"
check "the state of the service is asked on the machine" 0 service_here service_active
check "the state is asked without root" 0 grep -q -e "^systemctl is-active --quiet $unit\$" "$work/calls"
check "asking for the state does not use sudo" 1 grep -q -e '^sudo' "$work/calls"
: > "$work/calls"
check "the documented start command runs" 0 service_here service_start_enable
check "the documented start command runs as root" 0 grep -q -e "^sudo systemctl enable --now $unit\$" "$work/calls"
: > "$work/calls"
check "a restart runs" 0 service_here service_restart
check "a restart runs as root" 0 grep -q -e "^sudo systemctl restart $unit\$" "$work/calls"

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

# The check after a removal, and the record before the install, look at what the package can
# affect and nothing else: the job of the program's unit and the units that failed. A stand-in
# systemctl answers from files, one line per call, and keeps the last line: $work/answers/failed
# for "list-units --state=failed" and $work/answers/jobs for "list-jobs". A line holds the units
# of that answer, separated by spaces; an empty line is an answer with none. The runner says
# "starting" to is-system-running all along, which must not matter. The stand-in sleep returns
# at once: the calls are counted, not the seconds.
mkdir "$work/settle" "$work/answers"
cat > "$work/settle/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$FAKE_ANSWERS/asked"
case "$*" in
"list-units --state=failed --plain --no-legend") kind=failed format='%s loaded failed failed Some description\n' ;;
"list-jobs --plain --no-legend") kind=jobs format='7 %s start running\n' ;;
"is-system-running") echo starting; exit 1 ;;
*) echo "unexpected: systemctl $*" >&2; exit 2 ;;
esac
file="$FAKE_ANSWERS/$kind"
line="$(head -n 1 "$file")"
if [ "$(wc -l < "$file")" -gt 1 ]; then tail -n +2 "$file" > "$file.next" && mv "$file.next" "$file"; fi
for word in $line; do printf "$format" "$word"; done
EOF
printf '#!/bin/sh\n' > "$work/settle/sleep"
chmod 755 "$work/settle/systemctl" "$work/settle/sleep"

# $1 the answers about failed units, one per call (the first is the one before the install), $2
# the answers about jobs, one per call; the answers are separated by |, the units in one by spaces.
scenario() {
    printf '%s\n' "$1" | tr '|' '\n' > "$work/answers/failed"
    printf '%s\n' "$2" | tr '|' '\n' > "$work/answers/jobs"
    : > "$work/answers/asked"
}

# Records the units that failed before the install, then waits the way the check after the removal
# does. It gives up after 3 looks.
settles() {
    # The command is for the shell that env starts, which reads $1.
    # shellcheck disable=SC2016
    env PROGRAM=server VERSION=v1.2.3 REVISION=0 PACKAGE_DATE=20261112 HOST_SETTLE_SECONDS=3 \
        FAKE_ANSWERS="$work/answers" PATH="$work/settle:$work/bin:$PATH" \
        sh -c 'cd "$1" && . scripts/package-lib.sh && . scripts/service-test-host-deb.sh && record_failed_units && wait_booted deb host' sh "$root"
}

scenario "" ""
check "a machine with nothing failed and no job is healthy" 0 settles
scenario "old.service|old.service|old.service" ""
check "a unit that failed before the install is fine" 0 settles
scenario "old.service|old.service new.service" ""
check "a unit that failed after the install is not healthy" 1 settles
said "the new failed unit is named" "new.service"
check "the unit that failed before the install is not named" 1 grep -q -e 'old.service' "$work/out"
scenario "|new.service|" ""
check "a unit that failed after the install and is no longer failed is fine" 0 settles
scenario "" "$unit|$unit|"
check "a job for the unit that goes away is fine" 0 settles
scenario "" "$unit"
check "a job for the unit that stays is not healthy" 1 settles
said "the pending job is named" "$unit"
scenario "" "other.service"
check "a job for another unit is fine" 0 settles
scenario "" ""
check "a machine that says starting all along is fine" 0 settles
check "the state of the whole machine is not asked" 1 grep -q -e 'is-system-running' "$work/answers/asked"
# A systemctl that fails to answer is not the same as a machine with nothing failed.
mkdir "$work/broken"
printf '#!/bin/sh\nexit 1\n' > "$work/broken/systemctl"
chmod 755 "$work/broken/systemctl"
# The command is for the shell that env starts, which reads $1.
# shellcheck disable=SC2016
check "a machine whose failed units cannot be listed is not recorded" 1 env PATH="$work/broken:$PATH" PROGRAM=server VERSION=v1.2.3 REVISION=0 PACKAGE_DATE=20261112 \
    sh -c 'cd "$1" && . scripts/package-lib.sh && . scripts/service-test-host-deb.sh && record_failed_units' sh "$root"

# The runner starts the job while its own boot may still be going on, and it may stay "starting"
# for minutes; that boot is not ours. The test records which units failed before the install and
# compares after the removal, so only what the package changed counts. The order is read from the
# script: the record comes before the install, and nothing waits for the machine to boot.
record_line="$(grep -n -m 1 '^record_failed_units' "$root/scripts/service-test-host.sh" | cut -d: -f1)"
install_line="$(grep -n -m 1 '^install_package ' "$root/scripts/service-test-host.sh" | cut -d: -f1)"
before_install() { [ -n "$record_line" ] && [ -n "$install_line" ] && [ "$record_line" -lt "$install_line" ]; }
check "the failed units are recorded before the install" 0 before_install
check "the test does not wait for the machine to finish booting" 1 grep -q -e '^wait_booted ' "$root/scripts/service-test-host.sh"

[ "$failed" -eq 0 ]
