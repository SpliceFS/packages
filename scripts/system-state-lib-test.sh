#!/bin/sh
# check: system-state-lib.sh: no process of ours is found by the folder of the programs of the format, and the Linux listing names a removed program as it was
# Test of no_process_of_ours (scripts/system-state-lib.sh) and of running_programs as the Linux adapters
# have it (scripts/service-linux-lib.sh). The check asks the adapter which programs run and looks at
# them for the programs of ours in the folder the table of scripts/package-lib.sh gives the format, so
# the cases take a listing from a file and need no process. The Linux listing is proved on real
# processes, which only a system with /proc has: elsewhere it says so, and CI runs it on Linux (make
# check). FreeBSD lists with ps: scripts/service-test-pkg-test.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
child=""
trap '[ -z "$child" ] || kill "$child" 2>/dev/null || true; rm -rf "$work"' EXIT
failed=0
own="$work/own"
mkdir "$own"
# The library of the package scripts reads these.
export PROGRAM=server VERSION=v1.2.3 PACKAGE_DATE=20261112

. scripts/service-run-local.sh
. scripts/system-state-lib.sh

report() {
    if [ "$1" = ok ]; then printf 'ok   %s\n' "$2"; else
        printf 'FAIL %s\n' "$2"
        failed=$((failed + 1))
    fi
}

# What a failed case printed, under its line.
detail() {
    sed 's/^/     /' "$1" || true
}

# The adapter of these cases lists what the file $work/listed holds, and fails when $work/listing-fails exists.
running_programs() {
    [ ! -f "$work/listing-fails" ] || return 1
    cat "$work/listed"
}

# $1 what is checked, $2 the format, $3 the status wanted, $4 the listing, a line for each program.
# fail ends the subshell the check runs in, as it ends the steps. The check is one command whose status is the
# answer, so set -e being off inside it changes nothing.
check_ours() {
    printf '%s\n' "$4" >"$work/listed"
    status=0
    (
        FORMAT="$2"
        export FORMAT
        . scripts/package-lib.sh
        # shellcheck disable=SC2310
        no_process_of_ours system
    ) >"$work/out" 2>&1 || status=$?
    if [ "$status" -eq "$3" ]; then report ok "$1"; else
        report fail "$1: want status $3, got $status"
        detail "$work/out"
    fi
}

# Whether the output of the last check holds the text $2, which the case $1 is about.
said() {
    if grep -qF "$2" "$work/out"; then report ok "$1"; else
        report fail "$1: \"$2\" is not said"
        detail "$work/out"
    fi
}

check_ours "a program of ours in the folder of the programs is a process of ours (deb)" deb 1 "/usr/bin/splicefsd"
check_ours "so is the other program, and the client (rpm)" rpm 1 "/usr/bin/splicefsctl"
check_ours "and the programs of Alpine, in the same folder" apk 1 "$(printf '/sbin/init\n/usr/bin/splicefs')"
check_ours "and those of FreeBSD, in the folder of its table" pkg 1 "$(printf '/sbin/init\n/usr/local/bin/splicefsdctl')"
check_ours "no program of ours listed is no process of ours" deb 0 "$(printf '/sbin/init\n/usr/bin/dash\n/usr/sbin/cron')"
check_ours "a program of that name outside the folder of the format is not ours" deb 0 "/tmp/build/splicefsd"
check_ours "the folder of FreeBSD is not the one of the other formats" deb 0 "/usr/local/bin/splicefsd"
check_ours "and the folder of the other formats is not the one of FreeBSD" pkg 0 "/usr/bin/splicefsd"
check_ours "a system that lists nothing has no process of ours" deb 0 ""

: >"$work/listing-fails"
check_ours "a listing that fails is a failed check, not the answer that nothing runs" deb 1 "/sbin/init"
said "the failure says the listing failed" "listing the running programs failed"
rm "$work/listing-fails"
check_ours "a process of ours is named in what the check prints" deb 1 "/usr/bin/splicefsd"
said "the program that runs is named" "a process of ours is running: /usr/bin/splicefsd"

# The Linux adapter: the file the kernel says a process runs. The process is a copy of the shell, named like
# ours, that waits to read a line from a pipe the test holds open; closing the pipe ends it. The test goes
# on once the process has become that program (its exe says so), which is what is waited for, not time.
# Opening the pipe for writing returns when the process has opened it for reading.
unset -f running_programs
. scripts/service-linux-lib.sh
# Whether $work/bin/splicefsd is in the listing: the case that says so is $1, the status wanted $2.
listed_is() {
    # The listing is one command whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    running_programs system >"$work/listed" || { report fail "$1: the listing failed"; return 0; }
    status=0
    grep -qxF "$work/bin/splicefsd" "$work/listed" || status=1
    if [ "$status" -eq "$2" ]; then report ok "$1"; else
        report fail "$1"
        grep splicefsd "$work/listed" || echo "     it is not listed"
    fi
}

# Whether the process $1 runs the file $2.
runs_file() {
    exe_file="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
    [ "$exe_file" = "$2" ]
}

if [ -d /proc/self ]; then
    mkdir "$work/bin"
    shell_file="$(command -v sh)"
    cp "$shell_file" "$work/bin/splicefsd"
    mkfifo "$work/hold"
    "$work/bin/splicefsd" -c 'read -r line; exit 0' <"$work/hold" &
    child=$!
    exec 3>"$work/hold"
    # shellcheck disable=SC2310
    while kill -0 "$child" 2>/dev/null && ! runs_file "$child" "$work/bin/splicefsd"; do :; done
    listed_is "the Linux listing names the file a process runs" 0
    rm "$work/bin/splicefsd"
    listed_is "a program whose file was removed is named as it was, without the suffix the kernel adds" 0
    exec 3>&-
    wait "$child"
    child=""
    listed_is "a program that ended is not listed" 1
else
    echo "skip the Linux listing: this system has no /proc, CI and the containers run it"
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "system state lib: all cases as expected"
