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
printf 'rpm ghcr.io/splicefs/server-rocky-9:v1.0\napk ghcr.io/splicefs/server-alpine-3.22:v1.0\n' \
    >>"$t/farm/packaging/test-systems"
cat >"$t/bin/curl" <<'STAND_IN'
#!/bin/sh
# Stand-in curl. The health endpoint of the service answers 200 while the service of that system is
# active (the stand-in docker publishes the port 20000 plus the number of the system) and nothing
# otherwise; it is not logged, so that the log holds the downloads only. Any other address is logged
# and writes a file for the output name.
case "$*" in
    *"/api/v1/health"*)
        for url; do :; done
        port="${url#https://127.0.0.1:}"
        number=$((${port%%/*} - 20000))
        for active in "$STAND_IN_DIR"/active.*-"$number"; do
            if [ -f "$active" ]; then printf 200; exit 0; fi
        done
        printf 000
        exit 0
        ;;
    *) ;;
esac
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
# in the system), config.SYSTEM (exists while dpkg keeps the configuration of a package that was
# removed and not purged: the other package managers keep nothing), enabled.SYSTEM and active.SYSTEM
# (exist while the service is enabled and running), and for the n-th snapshot or core listing of a
# system the files snapshot.n and cores.n. A system is named in the call by its container, so that
# the systems of one case, which run at the same time, do not share what the stand-in remembers. The
# package manager and service manager commands of the three formats change that state; a container
# that restarts runs the service again when it is enabled, as a booted system does. STAND_IN_USER is
# the user the service runs as. STAND_IN_FIREWALLD, when set, makes every system run firewalld: its
# zone files are the folder zones.SYSTEM, which starts as a copy of zones-initial, are what docker cp
# and test -f and rm -f of /etc/firewalld/zones see, and --add-port writes the zone with the port and
# the zone before it; the port counts as open while the file public.xml says so, or always when
# STAND_IN_PORT_OPEN is set.
echo "docker $*" >>"$STAND_IN_DIR/log"
# A pattern removed from $* is removed from each argument, so the call is joined first.
call="$*"
rest="${call#*splicefs-package-test-}"
system="${rest%% *}"
# A path in the container, as docker cp names it, is CONTAINER:/path.
system="${system%%:*}"
next_number() {
    n=$(($(cat "$STAND_IN_DIR/$1.$system.count" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STAND_IN_DIR/$1.$system.count"
    echo "$n"
}
case "$1" in
    version) echo linux/amd64; exit 0 ;;
    inspect) echo true; exit 0 ;;
    port) echo "127.0.0.1:$((20000 + ${system##*-}))"; exit 0 ;;
    exec | restart | cp) ;;
    *) exit 0 ;;
esac
# The zone files of the system, made when a call first asks for them.
zone_folder() {
    [ -d "$STAND_IN_DIR/zones.$system" ] || cp -R "$STAND_IN_DIR/zones-initial" "$STAND_IN_DIR/zones.$system"
    echo "$STAND_IN_DIR/zones.$system"
}
# The path on this machine of a path that docker cp names: a zone file of the container is in the folder.
host_path() {
    case "$1" in
        *:/etc/firewalld/zones/*) echo "$(zone_folder)/${1##*/}" ;;
        *) echo "$1" ;;
    esac
}
if [ -n "${STAND_IN_FAIL:-}" ]; then
    case "$*" in *"$STAND_IN_FAIL"*) exit 1 ;; *) ;; esac
fi
case "$*" in
    *is-system-running*) echo running ;;
    *rc-status*) echo default ;;
    "cp "*) cp "$(host_path "$2")" "$(host_path "$3")" ;;
    *"firewall-cmd --state") [ -n "${STAND_IN_FIREWALLD:-}" ] ;;
    *"test -f /etc/firewalld/zones/"*) [ -f "$(zone_folder)/${call##*/}" ] ;;
    *"rm -f /etc/firewalld/zones/"*) rm -f "$(zone_folder)/${call##*/}" ;;
    *"firewall-cmd --permanent --add-port="*)
        echo "zone before the last change" >"$(zone_folder)/public.xml.old"
        echo "zone with the port ${call##*=}" >"$(zone_folder)/public.xml"
        ;;
    *"firewall-cmd --query-port="*)
        if [ -n "${STAND_IN_PORT_OPEN:-}" ] || grep -q "with the port ${call##*=}" "$(zone_folder)/public.xml" 2>/dev/null; then
            echo yes
        else
            echo no
            exit 1
        fi
        ;;
    restart*) [ -f "$STAND_IN_DIR/enabled.$system" ] || rm -f "$STAND_IN_DIR/active.$system" ;;
    *"systemctl enable"* | *"rc-update add"*) : >"$STAND_IN_DIR/enabled.$system" ;;
    *"systemctl disable"* | *"rc-update del"*) rm -f "$STAND_IN_DIR/enabled.$system" ;;
    *"systemctl start"* | *"systemctl restart"* | *"rc-service splicefsd start"* | *"rc-service splicefsd restart"*)
        : >"$STAND_IN_DIR/active.$system"
        ;;
    *"systemctl stop"* | *"rc-service splicefsd stop"*) rm -f "$STAND_IN_DIR/active.$system" ;;
    *is-enabled*) [ -f "$STAND_IN_DIR/enabled.$system" ] ;;
    *is-active* | *"rc-service splicefsd status"*) [ -f "$STAND_IN_DIR/active.$system" ] ;;
    *"rc-update show"*) [ ! -f "$STAND_IN_DIR/enabled.$system" ] || echo " splicefsd | default" ;;
    *"systemctl show"* | *'= "/usr/bin/$1"'*) [ -f "$STAND_IN_DIR/active.$system" ] && echo 4242 ;;
    *getent*) echo "${STAND_IN_USER:-splicefs}" ;;
    *"grep -q /usr/local/bin"*) exit 1 ;;
    *lifecycle-snapshot.sh*) cat "$STAND_IN_DIR/snapshot.$(next_number snapshot)" ;;
    *core-files.sh*) cat "$STAND_IN_DIR/cores.$(next_number cores)" 2>/dev/null || true ;;
    *package_held*splicefs-server*) [ -f "$STAND_IN_DIR/installed.$system" ] || [ -f "$STAND_IN_DIR/config.$system" ] ;;
    *package_held*) exit 1 ;;
    *"then echo steps/uninstall-dnf.sh"*) echo steps/uninstall-dnf.sh ;;
    *dpkg-query* | *"rpm -q"* | *"apk info -e"*) [ -f "$STAND_IN_DIR/installed.$system" ] ;;
    *"apt-get purge"*) rm -f "$STAND_IN_DIR/installed.$system" "$STAND_IN_DIR/config.$system" ;;
    *"apt-get remove"*) mv "$STAND_IN_DIR/installed.$system" "$STAND_IN_DIR/config.$system" ;;
    *"dnf remove"* | *"apk del"*) rm -f "$STAND_IN_DIR/installed.$system" ;;
    *"apt-get install"* | *"dnf install"* | *"apk add"*)
        rm -f "$STAND_IN_DIR/config.$system"
        : >"$STAND_IN_DIR/installed.$system"
        ;;
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
    user=splicefs
    firewalld=
    zones=
    port_open=
    target=ghcr.io/splicefs/server-debian-12:v1.0
}

# Starts the case $1 in the background with the settings of scenario: the snapshot of step 0 is
# $first, the snapshot of step 9 is $last, the one after the reinstall is $reinstalled, $cores are
# the cores listed at the fourth look (before step 3), $user is the user the service runs as, $target
# the image or format. $firewalld, when not empty, makes the systems run firewalld, and $zones names the
# zone files it has before the test (public.xml and public.xml.old, or neither); $port_open makes the
# port stay open in it. A call that
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
    # Bytes a copy by line would change: a carriage return and no newline at the end.
    mkdir -p "$case_dir/dir/zones-initial"
    for zone in $zones; do printf 'zone %s\r\nas shipped' "$zone" >"$case_dir/dir/zones-initial/$zone"; done
    (
        status=0
        STAND_IN_FAIL="$fail_on" STAND_IN_DIR="$case_dir/dir" PATH="$t/bin:$PATH" PROGRAM=server ONLY="$target" \
            STAND_IN_UNPROVEN="$unproven" STAND_IN_NO_SITE="$no_site" STAND_IN_USER="$user" \
            STAND_IN_FIREWALLD="$firewalld" STAND_IN_PORT_OPEN="$port_open" \
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
# The package is not installed again between the plain removal and the documented removal: the
# documented removal is for what the package manager still holds. $1 is the text of an install
# call, $2 the text of the removal call.
no_install_after_the_plain_removal_of() {
    last_install="$(grep -n -F "$1" "$dir/log" | tail -n 1 | cut -d: -f1)"
    removal="$(line_of "$2")"
    [ "$last_install" -lt "$removal" ]
}
# The removal of the test data (the folder the share serves) comes after the documented removal and
# before the last snapshot, which is the last call of the log that takes one.
test_data_removed_before_the_last_snapshot() {
    last="$(grep -n -F lifecycle-snapshot.sh "$dir/log" | tail -n 1 | cut -d: -f1)"
    purge="$(line_of 'apt-get purge')"
    removed="$(line_of remove_test_data)"
    [ "$purge" -gt 0 ] && [ "$removed" -gt "$purge" ] && [ "$removed" -lt "$last" ]
}
# The line number of the last call in the log that holds the text $1, or 0.
last_line_of() {
    n="$(grep -n -F -e "$1" "$dir/log" | tail -n 1 | cut -d: -f1)"
    echo "${n:-0}"
}
# On a system that runs firewalld: step 4 saves the zone files, then opens the port, then starts the
# service; step 9 puts the files back with the call whose text is $1, after the test data is removed,
# reloads the firewall, and asks whether the port is closed, all before the last snapshot, which is the
# last call of the log that takes one.
firewall_zones_saved_then_put_back_by() {
    saved="$(line_of 'test -f /etc/firewalld/zones/public.xml')"
    opened="$(line_of '--add-port=8480/tcp')"
    started="$(line_of 'systemctl start')"
    removed="$(line_of remove_test_data)"
    restored="$(last_line_of "$1")"
    reloaded="$(last_line_of 'firewall-cmd --reload')"
    queried="$(last_line_of '--query-port=8480/tcp')"
    last="$(last_line_of lifecycle-snapshot.sh)"
    [ "$saved" -gt 0 ] && [ "$opened" -gt "$saved" ] && [ "$started" -gt "$opened" ] &&
        [ "$restored" -gt "$removed" ] && [ "$removed" -gt "$started" ] && [ "$reloaded" -gt "$restored" ] &&
        [ "$queried" -gt "$reloaded" ] && [ "$queried" -lt "$last" ]
}
# The zone files of the system are what they were before the test, byte for byte, and no file is left
# that was not there.
zones_as_they_were() { diff -r "$dir/zones-initial" "$dir"/zones.* >/dev/null; }
steps_run() {
    # The line that says the removal command is left out starts like a step and is no step.
    steps_seen="$(grep '^step ' "$out" | cut -c1-7 | uniq | tr '\n' ' ')"
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
scenario; target=ghcr.io/splicefs/server-rocky-9:v1.0; launch rpm_holds_nothing
scenario; target=ghcr.io/splicefs/server-alpine-3.22:v1.0; launch apk_holds_nothing
scenario; fail_on="systemctl enable"; launch enable_fails
scenario; fail_on=write_test_config; launch test_config_not_written
scenario; fail_on=check_test_config; launch test_config_not_where_documented
scenario; fail_on="systemctl start"; launch start_fails
scenario; user=root; launch runs_as_root
scenario; fail_on="systemctl restart"; launch restart_fails
scenario; fail_on="restart splicefs-package-test"; launch container_restart_fails
scenario; fail_on=readlink; launch process_left_after_stop
scenario; fail_on="systemctl disable"; launch disable_fails
scenario; fail_on="apt-get remove"; launch plain_removal_fails
scenario; fail_on="verify_markers_kept plain removal"; launch plain_removal_takes_files
scenario; fail_on=check_programs_removed; launch plain_removal_keeps_program
scenario; last="/etc/b"; launch snapshot_differs
scenario; cores="/core pid 7 program splicefsd: /usr/bin/splicefsd"; launch core_dump
rocky=ghcr.io/splicefs/server-rocky-9:v1.0
scenario; target=$rocky; firewalld=1; zones="public.xml public.xml.old"; launch zones_existed
scenario; target=$rocky; firewalld=1; launch zones_missing
scenario; target=$rocky; firewalld=1; zones="public.xml.old"; launch one_zone_existed
scenario; target=$rocky; firewalld=1; port_open=1; launch port_stays_open
scenario; target=$rocky; firewalld=1; zones="public.xml public.xml.old"; fail_on="firewall-zones/public.xml.old"; launch zone_not_saved
wait

use_case good
expect "a good run passes" passed_status
expect "the steps run in order: 0, 1, 2, 3, 4, 5, 7, 8, 9" \
    steps_run 'step 0: step 1: step 2: step 3: step 4: step 5: step 7: step 8: step 9: '
expect "the published package file is fetched from the site" sh -c "grep -q 'curl.*/server/$old_file' '$dir/log'"
expect "the published package file is proven by the signed index" sh -c "grep -q 'verify $old_file ' '$dir/log'"
expect "the first snapshot is taken before the published package is installed" \
    in_order lifecycle-snapshot.sh "apt-get install -y -qq /pkg/published/splicefs-server_1.2.2_amd64.deb"
expect "the new file goes over the published one, then over itself, then the plain removal, then the documented" \
    in_order "apt-get install -y -qq /pkg/published/" \
    "sh deb v1.2.2 v1.2.3 file /pkg/splicefs-server_1.2.3_amd64.deb" \
    "sh deb v1.2.3 v1.2.3 file /pkg/splicefs-server_1.2.3_amd64.deb" \
    "apt-get remove" "apt-get purge"
expect "the service is enabled, configured, started, restarted, the container restarted, stopped, disabled, then removed" \
    in_order "systemctl enable" write_test_config "systemctl start" "systemctl restart" "docker restart" \
    "systemctl stop" "systemctl disable" "apt-get remove" "apt-get purge"
expect "the test configuration is checked where the documentation says before the service starts" \
    in_order write_test_config check_test_config "systemctl start"
expect "the port of the service is published, so that the health endpoint is asked from outside" \
    sh -c "grep -q 'docker run.* -p 127.0.0.1::8480 ' '$dir/log'"
expect "the service runs as its own user" holds "ok: runs as splicefs"
expect "the health endpoint answers from outside" holds "ok: answers 200 on /api/v1/health from outside"
expect "the service is active and answering after a restart" holds "ok: active and answering after a restart"
expect "the service is active and answering after the container restarts, because it is enabled" \
    holds "ok: active and answering after a reboot, because it was enabled"
expect "after the stop the service is silent and nothing of ours runs" holds "ok: stopped and silent"
expect "after the stop no process of ours is left" holds "ok: no process of ours is running after the stop"
expect "after the disable the service is not enabled" holds "ok: the service is not enabled"
expect "the test data is removed after the documented removal, before the last snapshot" test_data_removed_before_the_last_snapshot
expect "a system without firewalld has nothing changed in its firewall" \
    sh -c "! grep -q -e '--add-port' -e '--reload' -e 'docker cp' '$dir/log'"
expect "the removals fall between the first and the last snapshot" four_snapshots_around_the_removals
expect "the package file is not installed again between the plain removal and the documented removal" \
    no_install_after_the_plain_removal_of 'apt-get install' 'apt-get remove'
expect "the configuration file and the data file are written after the published install, kept by the upgrade" \
    in_order "apt-get install -y -qq /pkg/published/" "write_markers deb" "sh deb v1.2.2 v1.2.3" "verify_markers_kept upgrade"
expect "the plain removal checks the configuration and the data remain" sh -c "grep -q 'verify_markers_kept plain removal' '$dir/log'"
expect "the system is named as passed" holds "ok   deb $debian"
expect "the install is of the package file under /pkg" sh -c "grep -q 'file /pkg/splicefs-server_' '$dir/log'"
expect "no setup script and no repository are used" sh -c "! grep -q 'setup.sh\|apt-key\|sources.list' '$dir/log'"
expect "the setup script's removal is not run" sh -c "! grep -q 'splicefs-setup.sh' '$dir/log'"
expect "the documented removal names the package the package manager still holds (dpkg keeps its configuration)" \
    sh -c "grep -q 'apt-get purge splicefs-server' '$dir/log'"
expect "the documented removal leaves out the program that is not held" sh -c "! grep -q 'apt-get purge.*splicefs-client' '$dir/log'"
expect "the package manager is asked what it holds, once for each program" sh -c "[ \"\$(grep -c 'package_held' '$dir/log')\" -eq 2 ]"
expect "a removal command with names does not say it is left out" lacks "the removal command is left out"
expect "every other line of the steps file runs as written" \
    sh -c "grep -q 'apt-get autoremove --purge' '$dir/log' && grep -q 'userdel splicefs' '$dir/log'"

alpine=ghcr.io/splicefs/server-alpine-3.22:v1.0
use_case rpm_holds_nothing
expect "an rpm run passes" passed_status
expect "the system is named as passed" holds "ok   rpm $rocky"
expect "the documented removal says its removal command is left out, with the format" \
    holds "step 9: rpm: nothing installed, the removal command is left out, as the steps say"
expect "the removal command is not run again after the plain removal" sh -c "[ \"\$(grep -c 'dnf remove' '$dir/log')\" -eq 1 ]"
expect "every other line of the steps file runs as written" \
    sh -c "grep -q 'dnf autoremove' '$dir/log' && grep -q 'userdel splicefs' '$dir/log'"
expect "the package file is not installed again" no_install_after_the_plain_removal_of 'dnf install' 'dnf remove'

use_case apk_holds_nothing
expect "an apk run passes" passed_status
expect "the system is named as passed" holds "ok   apk $alpine"
expect "the documented removal says its removal command is left out, with the format" \
    holds "step 9: apk: nothing installed, the removal command is left out, as the steps say"
expect "the removal command is not run again after the plain removal" sh -c "[ \"\$(grep -c 'apk del' '$dir/log')\" -eq 1 ]"
expect "every other line of the steps file runs as written" \
    sh -c "grep -q 'deluser splicefs' '$dir/log' && grep -q 'rm -rf /var/lib/splicefs' '$dir/log'"
expect "the package file is not installed again" no_install_after_the_plain_removal_of 'apk add' 'apk del'

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
expect "the steps run in order with nothing published" \
    steps_run 'step 0: step 1: step 2: step 3: step 4: step 5: step 7: step 8: step 9: '
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

use_case enable_fails
expect "a failing enable command is step 3" holds "FAIL deb $debian (step 3)"
expect "that stops the run: no start" lacks "step 4:"
use_case test_config_not_written
expect "a test configuration that cannot be written is step 3" holds "FAIL deb $debian (step 3)"
expect "that stops the run: no start" lacks "step 4:"
use_case test_config_not_where_documented
expect "a test configuration not where the documentation says is step 3" holds "FAIL deb $debian (step 3)"
use_case start_fails
expect "a failing start command is step 4" holds "FAIL deb $debian (step 4)"
expect "that stops the run: no restart" lacks "step 5:"
use_case runs_as_root
expect "a service that runs as another user fails step 4" holds "FAIL deb $debian (step 4)"
expect "the user is named" holds "the service runs as 'root', not as 'splicefs'"
use_case restart_fails
expect "a failing restart is step 5" holds "FAIL deb $debian (step 5)"
use_case container_restart_fails
expect "a failing restart of the container is step 5" holds "FAIL deb $debian (step 5)"
expect "that stops the run: no stop" lacks "step 7:"
use_case process_left_after_stop
expect "a process of ours left after the stop is step 7" holds "FAIL deb $debian (step 7)"
expect "that stops the run: no disable" lacks "step 8:"
use_case disable_fails
expect "a failing disable command is step 8" holds "FAIL deb $debian (step 8)"
expect "that stops the run: no removal" sh -c "! grep -q 'apt-get remove' '$dir/log'"

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

# Step 4 opens the port in the firewall and changes zone files that did not exist before; step 9 puts
# each file back as it was, or deletes it when it was not there.
use_case zones_existed
expect "a run on a system with firewalld passes" passed_status
expect "the zone files are saved, the port opened, and the saved files put back before the last snapshot" \
    firewall_zones_saved_then_put_back_by 'firewall-zones/public.xml splicefs-package-test-'
expect "both zone files are put back" sh -c "grep -q 'firewall-zones/public.xml.old splicefs-package-test-' '$dir/log'"
expect "the zone files are as they were, byte for byte" zones_as_they_were
expect "no zone file is deleted when it existed" sh -c "! grep -q 'rm -f /etc/firewalld' '$dir/log'"

use_case zones_missing
expect "a run on a system with firewalld and no zone files passes" passed_status
expect "the missing zone files are deleted after the removals, before the last snapshot" \
    firewall_zones_saved_then_put_back_by 'rm -f /etc/firewalld/zones/public.xml.old'
expect "both zone files are deleted" sh -c "grep -q 'rm -f /etc/firewalld/zones/public.xml\$' '$dir/log'"
expect "no zone file is left that was not there" zones_as_they_were
expect "nothing is copied back into the system" sh -c "! grep -q 'firewall-zones/public.xml.* splicefs-package-test-' '$dir/log'"

use_case one_zone_existed
expect "a run where one zone file existed passes" passed_status
expect "the file that existed is put back and the file that did not is deleted" \
    sh -c "grep -q 'firewall-zones/public.xml.old splicefs-package-test-' '$dir/log' && grep -q 'rm -f /etc/firewalld/zones/public.xml\$' '$dir/log'"
expect "a file that existed is not deleted" sh -c "! grep -q 'rm -f /etc/firewalld/zones/public.xml.old' '$dir/log'"
expect "the zone files are as they were" zones_as_they_were

use_case port_stays_open
expect "a port that is still open after the zone files are put back fails the run" failed_status
expect "that is step 9" holds "FAIL rpm $rocky (step 9)"
expect "the open port is named" holds "the port 8480 is still open in the firewall"

use_case zone_not_saved
expect "a zone file that cannot be saved fails step 4" holds "FAIL rpm $rocky (step 4)"
expect "the port is not opened before the zone files are saved" sh -c "! grep -q -e '--add-port' '$dir/log'"

if [ "$failed" -ne 0 ]; then
    echo "$failed package-test case(s) failed"
    exit 1
fi
echo "package-test: all cases as expected"
