#!/bin/sh
# check: package-test.sh: the steps run in order, a failing check stops the system with its step named, cores are named
# Test of scripts/package-test.sh with a stand-in docker command, so it needs no Docker and no
# network. The stand-in writes every call to a log and answers like a system a package is installed
# in: the package manager commands change what it says is installed, snapshots and core listings
# come from files of the test, and a command that holds the text in STAND_IN_FAIL fails. The
# package site is a stand-in curl, and the proof of a download a stand-in published-verify.sh,
# which fails when the file is named in STAND_IN_UNPROVEN. The test reads the order of the steps
# from the log.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failed=0

# The repository as the script sees it, made once: the real scripts and definitions, apart from the
# proof of a download, which needs the network and gpg, and the list of systems, which has two of
# the format deb here. Every case gets its own folder of links to it and its own record of a build,
# so that the cases run at the same time.
mkdir -p "$t/farm/scripts" "$t/farm/packaging" "$t/bin"
ln -s "$root/programs" "$t/farm/programs"
ln -s "$root/steps" "$t/farm/steps"
for each in "$root"/scripts/* "$root"/packaging/*; do
    ln -s "$each" "$t/farm/${each#"$root"/}"
done
rm "$t/farm/scripts/published-verify.sh" "$t/farm/packaging/test-systems"
cat >"$t/farm/scripts/published-verify.sh" <<'STAND_IN'
#!/bin/sh
# Stand-in for the proof of a download: says what it was asked and fails for a named file.
echo "verify $*" >>"$STAND_IN_DIR/log"
[ -z "${STAND_IN_UNPROVEN:-}" ] || case "$1" in *"$STAND_IN_UNPROVEN"*) exit 1 ;; *) ;; esac
STAND_IN
chmod 755 "$t/farm/scripts/published-verify.sh"
printf 'deb ghcr.io/splicefs/server-debian-12:v1.0\ndeb ghcr.io/splicefs/server-ubuntu-24.04:v1.0\n' \
    >"$t/farm/packaging/test-systems"
cat >"$t/bin/curl" <<'STAND_IN'
#!/bin/sh
# Stand-in curl: logs the address and writes a file for the output name.
echo "curl $*" >>"$STAND_IN_DIR/log"
[ -z "${STAND_IN_NO_SITE:-}" ] || exit 22
while [ "$#" -gt 0 ]; do
    case "$1" in -o) echo published >"$2" ;; *) ;; esac
    shift
done
STAND_IN
chmod 755 "$t/bin/curl"

cat >"$t/bin/docker" <<'STAND_IN'
#!/bin/sh
# Stand-in docker. STAND_IN_DIR holds: log, installed.SYSTEM (exists while the package is installed
# in the system), and for the n-th snapshot or core listing of a system the files snapshot.n and
# cores.n. A system is named in the call by its container, so that the systems of one case, which
# run at the same time, do not share what the stand-in remembers.
echo "docker $*" >>"$STAND_IN_DIR/log"
# A pattern removed from $* is removed from each argument, so the call is joined first.
call="$*"
rest="${call#*splicefs-package-test-}"
system="${rest%% *}"
next_number() {
    n=$(($(cat "$STAND_IN_DIR/$1.$system.count" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STAND_IN_DIR/$1.$system.count"
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
    *dpkg-query*) [ -f "$STAND_IN_DIR/installed.$system" ] ;;
    *"apt-get purge"* | *"apt-get remove"*) rm -f "$STAND_IN_DIR/installed.$system" ;;
    *"apt-get install"*) : >"$STAND_IN_DIR/installed.$system" ;;
    *) ;;
esac
STAND_IN
chmod 755 "$t/bin/docker"

# What every case starts from: the record of the build names 1.2.2 as the published version, no
# call fails, no file changes, and the system of the image debian-12 is tested.
scenario() {
    record=1.2.2
    fail_on=
    reinstalled="/etc/a"
    unproven=
    no_site=
    first="/etc/a"
    last="/etc/a"
    cores=
    target=ghcr.io/splicefs/server-debian-12:v1.0
}

# Starts the case $1 in the background with the settings of scenario: the snapshot of step 0 is
# $first, the snapshot of step 9 is $last, the one after the reinstall is $reinstalled, $cores are
# the cores listed at the fourth look (before step 9), $target the image or format. A call that
# holds the text in $fail_on fails. Keeps the output in $t/cases/$1/out, the calls in
# $t/cases/$1/dir/log and the status in $t/cases/$1/status; the cases are read with use_case, after
# wait.
launch() {
    case_dir="$t/cases/$1"
    mkdir -p "$case_dir/dir" "$case_dir/root/dist/server"
    for each in scripts packaging programs steps; do ln -s "$t/farm/$each" "$case_dir/root/$each"; done
    printf 'VERSION=v1.2.3\nPACKAGE_DATE=20261112\nUPGRADE_FROM=%s\n' "$record" >"$case_dir/root/dist/server/version"
    printf '%s\n' "$first" >"$case_dir/dir/snapshot.1"
    printf '%s\n' "$first" >"$case_dir/dir/snapshot.2"
    printf '%s\n' "$reinstalled" >"$case_dir/dir/snapshot.3"
    printf '%s\n' "$last" >"$case_dir/dir/snapshot.4"
    [ -z "$cores" ] || printf '%s\n' "$cores" >"$case_dir/dir/cores.4"
    (
        status=0
        STAND_IN_FAIL="$fail_on" STAND_IN_DIR="$case_dir/dir" PATH="$t/bin:$PATH" PROGRAM=server ONLY="$target" \
            STAND_IN_UNPROVEN="$unproven" STAND_IN_NO_SITE="$no_site" \
            sh "$case_dir/root/scripts/package-test.sh" >"$case_dir/out" 2>&1 || status=$?
        echo "$status" >"$case_dir/status"
    ) &
}

# Points the checks that follow at the case $1: $out, $dir and $status.
use_case() {
    out="$t/cases/$1/out"
    dir="$t/cases/$1/dir"
    read -r status <"$t/cases/$1/status"
}

# The line number of the first call in the log that holds the text $1, or 0.
line_of() {
    n="$(grep -n -F -e "$1" "$dir/log" | head -n 1 | cut -d: -f1)"
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
        sed 's/^/     /' "$out"
        failed=$((failed + 1))
    fi
}

holds() { grep -q -F -e "$1" "$out"; }
lacks() { ! grep -q -F -e "$1" "$out"; }
# The calls named by the arguments are in the log, in that order.
in_order() {
    previous=0
    for call in "$@"; do
        n="$(line_of "$call")"
        [ "$n" -gt "$previous" ] || return 1
        previous="$n"
    done
}
# The number of lines of the log that hold the text $1.
calls_of() { grep -c -F -e "$1" "$dir/log" || true; }
# The package is removed between the first snapshot and the last, which is the last call of the
# log that takes one; the first four calls that take one are those of steps 0, 2 (twice) and 9.
four_snapshots_around_the_removals() {
    snapshots="$(calls_of lifecycle-snapshot.sh)"
    last="$(grep -n -F lifecycle-snapshot.sh "$dir/log" | tail -n 1 | cut -d: -f1)"
    removal="$(line_of 'apt-get purge')"
    [ "$snapshots" -eq 4 ] && [ "$removal" -gt 0 ] && [ "$removal" -lt "$last" ]
}
# The package file is installed again after the plain removal, so that the documented removal has
# a package to remove.
installed_again_before_the_documented_removal() {
    last_install="$(grep -n -F 'apt-get install' "$dir/log" | tail -n 1 | cut -d: -f1)"
    removal="$(line_of 'apt-get remove')"
    purge="$(line_of 'apt-get purge')"
    [ "$removal" -lt "$last_install" ] && [ "$last_install" -lt "$purge" ]
}
steps_run() {
    steps_seen="$(grep '^step ' "$out" | cut -c1-7 | tr '\n' ' ')"
    [ "$steps_seen" = "$1" ]
}
failed_status() { [ "$status" -ne 0 ]; }
passed_status() { [ "$status" -eq 0 ]; }

debian=ghcr.io/splicefs/server-debian-12:v1.0
old_file=apt/pool/main/s/splicefs-server/splicefs-server_1.2.2_amd64.deb

# Every case runs at the same time, because each is a process that starts a few hundred more.
scenario; launch good
scenario; target=deb; launch two_systems
scenario; record=1.2.3; launch same_version
scenario; record=none; launch nothing_published
scenario; no_site=1; launch no_site
scenario; unproven=.deb; launch unproven
scenario; fail_on=check_links; launch file_check_fails
scenario; fail_on="apt-get install"; launch baseline_install_fails
scenario; record=none; fail_on="apt-get install"; launch install_fails
scenario; fail_on="sh deb v1.2.2 v1.2.3"; launch upgrade_fails
scenario; fail_on="verify_markers_kept upgrade"; launch upgrade_loses_files
scenario; reinstalled="/etc/changed"; launch reinstall_changes_files
scenario; fail_on="verify_markers_kept reinstall"; launch reinstall_loses_files
scenario; fail_on="apt-get remove"; launch plain_removal_fails
scenario; fail_on="verify_markers_kept plain removal"; launch plain_removal_takes_files
scenario; fail_on=check_programs_removed; launch plain_removal_keeps_program
scenario; last="/etc/b"; launch snapshot_differs
scenario; cores="/core pid 7 program splicefsd: /usr/bin/splicefsd"; launch core_dump
wait

use_case good
expect "a good run passes" passed_status
expect "the steps run in order: 0, 1, 2, 9" steps_run 'step 0: step 1: step 2: step 9: '
expect "the published package file is fetched from the site" sh -c "grep -q 'curl.*/server/$old_file' '$dir/log'"
expect "the published package file is proven by the signed index" sh -c "grep -q 'verify $old_file ' '$dir/log'"
expect "the first snapshot is taken before the published package is installed" \
    in_order lifecycle-snapshot.sh "apt-get install -y -qq /pkg/published/splicefs-server_1.2.2_amd64.deb"
expect "the new file goes over the published one, then over itself, then the plain removal, then the documented" \
    in_order "apt-get install -y -qq /pkg/published/" \
    "sh deb v1.2.2 v1.2.3 file /pkg/splicefs-server_1.2.3_amd64.deb" \
    "sh deb v1.2.3 v1.2.3 file /pkg/splicefs-server_1.2.3_amd64.deb" \
    "apt-get remove" "apt-get purge"
expect "the removals fall between the first and the last snapshot" four_snapshots_around_the_removals
expect "the package file is installed again before the documented removal" installed_again_before_the_documented_removal
expect "the configuration file and the data file are written after the published install, kept by the upgrade" \
    in_order "apt-get install -y -qq /pkg/published/" "write_markers deb" "sh deb v1.2.2 v1.2.3" "verify_markers_kept upgrade"
expect "the plain removal checks the configuration and the data remain" sh -c "grep -q 'verify_markers_kept plain removal' '$dir/log'"
expect "the system is named as passed" holds "ok   deb $debian"
expect "the install is of the package file under /pkg" sh -c "grep -q 'apt-get install.* /pkg/splicefs-server_' '$dir/log'"
expect "no setup script and no repository are used" sh -c "! grep -q 'setup.sh\|apt-key\|sources.list' '$dir/log'"
expect "the setup script's removal is not run" sh -c "! grep -q 'splicefs-setup.sh' '$dir/log'"
expect "the documented removal names the package under test" sh -c "grep -q 'apt-get purge splicefs-server' '$dir/log'"
expect "the documented removal leaves out the program that is not tested" sh -c "! grep -q 'splicefs-client' '$dir/log'"

use_case two_systems
expect "two systems of one format pass" holds "passed: 2  failed: 0"
expect "the published file of a format is fetched once for all its systems" \
    sh -c "[ \"\$(grep -c 'curl.*/server/$old_file' '$dir/log')\" -eq 1 ] && [ \"\$(grep -c 'verify $old_file ' '$dir/log')\" -eq 1 ]"

use_case same_version
expect "a published file of the same version passes" passed_status
expect "the same version is put over the published one with the reinstall, and again over itself" \
    sh -c "[ \"\$(grep -c 'sh deb v1.2.3 v1.2.3 file' '$dir/log')\" -eq 2 ]"

use_case nothing_published
expect "a run with nothing published passes" passed_status
expect "the steps run in order with nothing published" steps_run 'step 0: step 1: step 2: step 9: '
expect "step 1 says nothing is published" holds "nothing is published for server"
expect "nothing is fetched or proven" sh -c "! grep -q 'curl\|verify ' '$dir/log'"
expect "no published file is installed" sh -c "! grep -q '/pkg/published' '$dir/log'"
expect "the new file is installed, and the configuration file and the data file are written" \
    in_order "apt-get install -y -qq /pkg/splicefs-server_1.2.3_amd64.deb" "write_markers deb" "sh deb v1.2.3 v1.2.3 file"

use_case no_site
expect "a download that fails fails the run" failed_status
expect "the failed download is named" holds "could not download and verify"
expect "no system is started when the download failed" sh -c "! grep -q 'docker run' '$dir/log'"

use_case unproven
expect "a file that does not prove fails the run" failed_status
expect "the file that does not prove is named" holds "could not download and verify"

use_case file_check_fails
expect "a failing file check fails the system" failed_status
expect "the failing step is named" holds "FAIL deb $debian (step 2)"
expect "a failing check stops the run: no step 9" lacks "step 9:"
expect "a failing check stops the run: no removal" sh -c "! grep -q 'apt-get purge' '$dir/log'"

use_case baseline_install_fails
expect "a failing install of the published file is step 1" holds "FAIL deb $debian (step 1)"
use_case install_fails
expect "a failing install with no published file is step 2" holds "FAIL deb $debian (step 2)"

use_case upgrade_fails
expect "a failing upgrade is step 2" holds "FAIL deb $debian (step 2)"
expect "a failing upgrade is named" holds "putting the new package over the published one failed"

use_case upgrade_loses_files
expect "an upgrade that loses the configuration or the data fails step 2" holds "FAIL deb $debian (step 2)"

use_case reinstall_changes_files
expect "a file that changes when the package is installed over itself fails step 2" holds "FAIL deb $debian (step 2)"
expect "the change is shown" holds "/etc/changed"

use_case reinstall_loses_files
expect "a reinstall that loses the configuration or the data fails step 2" holds "FAIL deb $debian (step 2)"

use_case plain_removal_fails
expect "a failing plain removal fails step 9" holds "FAIL deb $debian (step 9)"
expect "a failing plain removal stops the run: no documented removal" sh -c "! grep -q 'apt-get purge' '$dir/log'"

use_case plain_removal_takes_files
expect "a plain removal that takes the configuration or the data fails step 9" holds "FAIL deb $debian (step 9)"
expect "that stops the run: no documented removal" sh -c "! grep -q 'apt-get purge' '$dir/log'"

use_case plain_removal_keeps_program
expect "a program left behind by the plain removal fails step 9" holds "the plain removal left a program"

use_case snapshot_differs
expect "a snapshot that differs fails step 9" holds "FAIL deb $debian (step 9)"
expect "the difference is shown" holds "/etc/b"

use_case core_dump
expect "a core dump is named with the step before which it was found" holds "core dump after step 2: /core pid 7"

if [ "$failed" -ne 0 ]; then
    echo "$failed package-test case(s) failed"
    exit 1
fi
echo "package-test: all cases as expected"
