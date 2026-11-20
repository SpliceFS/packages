#!/bin/sh
# check: package-test.sh: the steps run in order, a failing check stops the system with its step named, cores are named
# Test of scripts/package-test.sh with a stand-in docker command, so it needs no Docker and no
# network. The stand-in writes every call to a log and answers like a system a package is installed
# in: the package manager commands change what it says is installed, snapshots and core listings
# come from files of the test, and a command that holds the text in STAND_IN_FAIL fails. The test
# reads the order of the steps from that log.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failed=0
fail_on=

# The repository as the script sees it: the real scripts and definitions, and a record of a build.
mkdir -p "$t/root/dist/server" "$t/bin"
for each in scripts programs packaging steps; do ln -s "$root/$each" "$t/root/$each"; done
printf 'VERSION=v1.2.3\nPACKAGE_DATE=20261112\nUPGRADE_FROM=\n' >"$t/root/dist/server/version"

cat >"$t/bin/docker" <<'STAND_IN'
#!/bin/sh
# Stand-in docker. STAND_IN_DIR holds: log, installed (exists while the package is installed), and
# for the n-th snapshot or core listing the files snapshot.n and cores.n.
echo "docker $*" >>"$STAND_IN_DIR/log"
next_number() {
    n=$(($(cat "$STAND_IN_DIR/$1.count" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STAND_IN_DIR/$1.count"
    echo "$n"
}
case "$1" in
    version) echo linux/amd64; exit 0 ;;
    inspect) echo true; exit 0 ;;
    exec) ;;
    *) exit 0 ;;
esac
if [ -n "${STAND_IN_FAIL:-}" ]; then
    case "$*" in *"$STAND_IN_FAIL"*) exit 1 ;; *) ;; esac
fi
case "$*" in
    *is-system-running*) echo running ;;
    *is-enabled* | *is-active*) exit 1 ;;
    *"grep -q /usr/local/bin"*) exit 1 ;;
    *lifecycle-snapshot.sh*) cat "$STAND_IN_DIR/snapshot.$(next_number snapshot)" ;;
    *core-files.sh*) cat "$STAND_IN_DIR/cores.$(next_number cores)" 2>/dev/null || true ;;
    *dpkg-query*) [ -f "$STAND_IN_DIR/installed" ] ;;
    *"apt-get purge"*) rm -f "$STAND_IN_DIR/installed" ;;
    *"apt-get install"*) : >"$STAND_IN_DIR/installed" ;;
    *) ;;
esac
STAND_IN
chmod 755 "$t/bin/docker"

# Runs the script against the stand-in with the snapshot files and core listings given as
# $1 (the snapshot of step 0), $2 (the snapshot of step 9) and $3 (the cores listed at the third
# look, which is before step 9), and the image $4. A call that holds the text in $fail_on
# fails. Keeps the output in $t/out and the calls in $t/dir/log; sets status.
run() {
    rm -rf "$t/dir" && mkdir "$t/dir"
    printf '%s\n' "$1" >"$t/dir/snapshot.1"
    printf '%s\n' "$2" >"$t/dir/snapshot.2"
    [ -z "$3" ] || printf '%s\n' "$3" >"$t/dir/cores.3"
    status=0
    STAND_IN_FAIL="$fail_on" STAND_IN_DIR="$t/dir" PATH="$t/bin:$PATH" PROGRAM=server ONLY="$4" \
        sh "$t/root/scripts/package-test.sh" >"$t/out" 2>&1 || status=$?
}

# The line number of the first call in the log that holds the text $1, or 0.
line_of() {
    n="$(grep -n -F -e "$1" "$t/dir/log" | head -n 1 | cut -d: -f1)"
    echo "${n:-0}"
}

# The name of the case, then the command that must succeed; the output is shown when it does not.
expect() {
    name="$1"
    shift
    if "$@"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        sed 's/^/     /' "$t/out"
        failed=$((failed + 1))
    fi
}

holds() { grep -q -F -e "$1" "$t/out"; }
lacks() { ! grep -q -F -e "$1" "$t/out"; }
# The calls named by $1, $2 and $3 are in the log, in that order.
in_order() {
    a="$(line_of "$1")"; b="$(line_of "$2")"; c="$(line_of "$3")"
    [ "$a" -gt 0 ] && [ "$b" -gt "$a" ] && [ "$c" -gt "$b" ]
}
# The package is removed between the first snapshot and the second, which is the last call of the
# log that takes one.
two_snapshots_around_the_removal() {
    snapshots="$(grep -c -F lifecycle-snapshot.sh "$t/dir/log")"
    last="$(grep -n -F lifecycle-snapshot.sh "$t/dir/log" | tail -n 1 | cut -d: -f1)"
    removal="$(line_of 'apt-get purge')"
    [ "$snapshots" -eq 2 ] && [ "$removal" -gt 0 ] && [ "$removal" -lt "$last" ]
}
failed_status() { [ "$status" -ne 0 ]; }
passed_status() { [ "$status" -eq 0 ]; }

debian=ghcr.io/splicefs/server-debian-12:v1.0

run "/etc/a" "/etc/a" "" "$debian"
expect "a good run passes" passed_status
expect "step 0 comes before step 2, which comes before step 9" sh -c "
    grep -n '^step ' '$t/out' | sed 's/:.*//' | tr '\n' ' ' | grep -q '^[0-9]* [0-9]* [0-9]* \$' &&
    [ \"\$(grep '^step ' '$t/out' | cut -c1-7 | tr '\n' ' ')\" = 'step 0: step 2: step 9: ' ]"
expect "the first snapshot is taken before the package is installed" in_order lifecycle-snapshot.sh "apt-get install" "apt-get purge"
expect "the package is removed before the second snapshot" two_snapshots_around_the_removal
expect "the system is named as passed" holds "ok   deb $debian"
expect "the install is of the package file under /pkg" sh -c "grep -q 'apt-get install.* /pkg/splicefs-server_' '$t/dir/log'"
expect "no setup script and no repository are used" sh -c "! grep -q 'setup.sh\|apt-key\|sources.list' '$t/dir/log'"
expect "the setup script's removal is not run" sh -c "! grep -q 'splicefs-setup.sh' '$t/dir/log'"
expect "the documented removal names the package under test" sh -c "grep -q 'apt-get purge splicefs-server' '$t/dir/log'"
expect "the documented removal leaves out the program that is not tested" sh -c "! grep -q 'splicefs-client' '$t/dir/log'"

fail_on=check_links
run "/etc/a" "/etc/a" "" "$debian"
expect "a failing file check fails the system" failed_status
expect "the failing step is named" holds "FAIL deb $debian (step 2)"
expect "a failing check stops the run: no step 9" lacks "step 9:"
expect "a failing check stops the run: no removal" sh -c "! grep -q 'apt-get purge' '$t/dir/log'"

fail_on="apt-get install"
run "/etc/a" "/etc/a" "" "$debian"
expect "a failing install is step 2" holds "FAIL deb $debian (step 2)"

fail_on=
run "/etc/a" "/etc/b" "" "$debian"
expect "a snapshot that differs fails step 9" holds "FAIL deb $debian (step 9)"
expect "the difference is shown" holds "/etc/b"

run "/etc/a" "/etc/a" "/core pid 7 program splicefsd: /usr/bin/splicefsd" "$debian"
expect "a core dump is named with the step before which it was found" holds "core dump after step 2: /core pid 7"

if [ "$failed" -ne 0 ]; then
    echo "$failed package-test case(s) failed"
    exit 1
fi
echo "package-test: all cases as expected"
