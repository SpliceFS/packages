#!/bin/sh
# check: package-test-steps.sh: the phases run their steps in order in a system, a failing check names its step in the result, cores are named
# Test of scripts/package-test-steps.sh, the steps that run inside the system under test. The system
# is a stand-in: its commands go through on_system (scripts/service-run-local.sh), which the
# test replaces with one that writes every call to a log and answers like a system a package is
# installed in, so it needs no Docker and no network. The package manager and service manager
# commands change what the stand-in says is installed, enabled and running; snapshots and core
# listings come from files of the test; a call that holds the text in STAND_IN_FAIL fails. The
# restart the host does between the phases is done by the test. The test reads the order of the
# steps from the log. The host's part is in scripts/package-test-test.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failed=0

# The repository as the script sees it, made once: the real scripts and definitions, apart from the
# commands of the system, which the stand-in on_system answers. Every case gets its own folder of
# links to it and its own record of a build, so that the cases run at the same time.
mkdir -p "$t/farm/scripts"
ln -s "$root/programs" "$t/farm/programs"
ln -s "$root/steps" "$t/farm/steps"
ln -s "$root/keys" "$t/farm/keys"
ln -s "$root"/scripts/* "$t/farm/scripts/"
rm "$t/farm/scripts/service-run-local.sh"
cat >"$t/farm/scripts/service-run-local.sh" <<'STAND_IN'
# Stand-in for the commands of the system. STAND_IN_DIR holds: log, installed.PROGRAM (exists while
# the package of the program, server or client, is installed), config.PROGRAM (exists while dpkg
# keeps the configuration of a package that was removed and not purged: the other package managers
# keep nothing), enabled and active (exist while the service of the server is enabled and running;
# the client's service never is), and for the n-th snapshot or core listing the files snapshot.n and
# cores.n, the look after the last snapshot (the file last-snapshot holds its number)
# cores.after-snapshot, and for a core given by its path the answer of a core that no step could
# read. The package manager and service manager commands of the three formats change that state.
# STAND_IN_USER is the user the service runs as. STAND_IN_FIREWALLD, when set, makes the system run
# firewalld: its zone files are the folder zones, which starts as a copy of zones-initial, are what
# cp and test -f and rm -f of /etc/firewalld/zones see, and --add-port writes the zone with the port
# and the zone before it; the port counts as open while the file public.xml says so, or always when
# STAND_IN_PORT_OPEN is set.
on_system() {
    shift
    call="$*"
    echo "$call" >>"$STAND_IN_DIR/log"
    stand_in_answer "$@"
}
on_system_as_root() {
    on_system "$@"
}

# A system the host cannot reach fetches its published package itself, with the hook of its format:
# STAND_IN_FETCH makes this stand-in exist. It logs its call, fails when STAND_IN_FAIL holds its name, and
# prints the path of the file it fetched, which is not the one the host would have put in /pkg. The
# second hook reads the version of that file, as a baseline file writes it: STAND_IN_FETCHED_SERVER or
# STAND_IN_FETCHED_CLIENT when set (the site listed a newer package when the system fetched than when
# the host read it), else the version the host read.
if [ -n "${STAND_IN_FETCH:-}" ]; then
    fetch_published_package() {
        echo "fetch_published_package $1" >>"$STAND_IN_DIR/log"
        case "${STAND_IN_FAIL:-}" in *fetch_published_package*) return 1 ;; *) ;; esac
        echo "/fetched/$PROGRAM/splicefs-$PROGRAM-published.deb"
    }
    published_baseline_version() {
        echo "published_baseline_version $1 $2" >>"$STAND_IN_DIR/log"
        case "${STAND_IN_FAIL:-}" in *published_baseline_version*) return 1 ;; *) ;; esac
        case "$PROGRAM" in server) fetched_version="${STAND_IN_FETCHED_SERVER:-}" ;; *) fetched_version="${STAND_IN_FETCHED_CLIENT:-}" ;; esac
        [ -n "$fetched_version" ] || read -r fetched_version <"$BASELINES/$PROGRAM"
        echo "$fetched_version"
    }
fi

# Nothing the stand-in does starts a process unless a command of a system does (cp, mv, rm): its
# answers are made of builtins, because a call that runs in a few milliseconds is a stand-in worth
# having and a process for each of hundreds of calls is not. So no function here prints a value for
# a command substitution to read; each sets a variable, and a file is read with read.

# Sets $named to the programs a call names by their package, as words: the install, removal and
# query commands.
name_programs() {
    named=
    case "$call" in *splicefs-server*) named=server ;; *) ;; esac
    case "$call" in *splicefs-client*) named="$named${named:+ }client" ;; *) ;; esac
}
# Sets $number to the next value of the counter $1, which the phases keep in a file (each phase is a
# shell of its own, as it is on the host).
next_number() {
    number=0
    [ ! -f "$STAND_IN_DIR/$1.count" ] || read -r number <"$STAND_IN_DIR/$1.count"
    number=$((number + 1))
    echo "$number" >"$STAND_IN_DIR/$1.count"
}
# Prints the file $1, which is a set of whole lines, or nothing when there is no such file.
print_file() {
    [ -f "$1" ] || return 0
    while IFS= read -r line; do
        printf '%s\n' "$line"
    done <"$1"
}
# The zone files of the system, made when a call first asks for them.
make_zone_folder() {
    [ -d "$STAND_IN_DIR/zones" ] || cp -R "$STAND_IN_DIR/zones-initial" "$STAND_IN_DIR/zones"
    zone_folder="$STAND_IN_DIR/zones"
}
# Sets $host_file to the path on this machine of a path of the system: a zone file is in the folder.
host_path() {
    host_file="$1"
    case "$1" in
        /etc/firewalld/zones/*)
            make_zone_folder
            host_file="$zone_folder/${1##*/}"
            ;;
        *) ;;
    esac
}
stand_in_answer() {
    if [ -n "${STAND_IN_FAIL:-}" ]; then
        case "$call" in *"$STAND_IN_FAIL"*) return 1 ;; *) ;; esac
    fi
    case "$call" in
        "cp "*"/etc/firewalld/zones/"*)
            host_path "$2"
            from_file="$host_file"
            host_path "$3"
            cp "$from_file" "$host_file"
            ;;
        *"firewall-cmd --state") [ -n "${STAND_IN_FIREWALLD:-}" ] ;;
        *"test -f /etc/firewalld/zones/"*)
            make_zone_folder
            [ -f "$zone_folder/${call##*/}" ]
            ;;
        *"rm -f /etc/firewalld/zones/"*)
            make_zone_folder
            rm -f "$zone_folder/${call##*/}"
            ;;
        *"firewall-cmd --permanent --add-port="*)
            make_zone_folder
            echo "zone before the last change" >"$zone_folder/public.xml.old"
            echo "zone with the port ${call##*=}" >"$zone_folder/public.xml"
            ;;
        *"firewall-cmd --query-port="*)
            make_zone_folder
            if [ -n "${STAND_IN_PORT_OPEN:-}" ] || grep -q "with the port ${call##*=}" "$zone_folder/public.xml" 2>/dev/null; then
                echo yes
            else
                echo no
                return 1
            fi
            ;;
        *"--quiet splicefs.service"* | *"rc-service splicefs status"*) return 1 ;;
        *"systemctl enable"* | *"rc-update add"*) : >"$STAND_IN_DIR/enabled" ;;
        *"systemctl disable"* | *"rc-update del"*) rm -f "$STAND_IN_DIR/enabled" ;;
        *"systemctl start"* | *"systemctl restart"* | *"rc-service splicefsd start"* | *"rc-service splicefsd restart"*)
            : >"$STAND_IN_DIR/active"
            ;;
        *"systemctl stop"* | *"rc-service splicefsd stop"*) rm -f "$STAND_IN_DIR/active" ;;
        *is-enabled*) [ -f "$STAND_IN_DIR/enabled" ] ;;
        *is-active* | *"rc-service splicefsd status"*) [ -f "$STAND_IN_DIR/active" ] ;;
        *"rc-update show"*) [ ! -f "$STAND_IN_DIR/enabled" ] || echo " splicefsd | default" ;;
        *"systemctl show"* | *'= "/usr/bin/$1"'*) [ -f "$STAND_IN_DIR/active" ] && echo 4242 ;;
        *getent*) echo "${STAND_IN_USER:-splicefs}" ;;
        *"grep -q /usr/local/bin"*) return 1 ;;
        *lifecycle-snapshot.sh*)
            next_number snapshot
            print_file "$STAND_IN_DIR/snapshot.$number"
            ;;
        *"core-files.sh /"*)
            for asked in ${call#*core-files.sh }; do
                echo "$asked: not a 64-bit ELF core with a process note: 40 bytes, starting 177 E L F"
            done
            ;;
        *core-files.sh*)
            next_number cores
            look="cores.$number"
            snapshots_taken=
            [ ! -f "$STAND_IN_DIR/snapshot.count" ] || read -r snapshots_taken <"$STAND_IN_DIR/snapshot.count"
            read -r last_snapshot <"$STAND_IN_DIR/last-snapshot"
            if [ "$snapshots_taken" = "$last_snapshot" ]; then
                look=cores.after-snapshot
            fi
            print_file "$STAND_IN_DIR/$look"
            ;;
        *package_held*splicefs-server*) [ -f "$STAND_IN_DIR/installed.server" ] || [ -f "$STAND_IN_DIR/config.server" ] ;;
        *package_held*splicefs-client*) [ -f "$STAND_IN_DIR/installed.client" ] || [ -f "$STAND_IN_DIR/config.client" ] ;;
        *package_held*) return 1 ;;
        *"then echo steps/uninstall-dnf.sh"*) echo steps/uninstall-dnf.sh ;;
        *dpkg-query* | *"rpm -q"* | *"apk info -e"*)
            name_programs
            [ -f "$STAND_IN_DIR/installed.$named" ]
            ;;
        *"apt-get purge"*)
            name_programs
            for each in $named; do rm -f "$STAND_IN_DIR/installed.$each" "$STAND_IN_DIR/config.$each"; done
            ;;
        *"apt-get remove"*)
            name_programs
            for each in $named; do mv "$STAND_IN_DIR/installed.$each" "$STAND_IN_DIR/config.$each"; done
            ;;
        *"dnf remove"* | *"apk del"*)
            name_programs
            for each in $named; do rm -f "$STAND_IN_DIR/installed.$each"; done
            ;;
        *"apt-get install"* | *"dnf install"* | *"apk add"*)
            name_programs
            for each in $named; do
                rm -f "$STAND_IN_DIR/config.$each"
                : >"$STAND_IN_DIR/installed.$each"
            done
            ;;
        *) ;;
    esac
}

# The commands the checks of the server run in the shell of the steps itself, not through on_system:
# the name and the address of the system, and the answer of its health endpoint, which is 200 while
# the service is active. They are functions, so a call starts no process.
uname() {
    echo stand-in
}
getent() {
    echo "172.17.0.2        STREAM stand-in"
}
curl() {
    if [ -f "$STAND_IN_DIR/active" ]; then printf 200; else printf 000; fi
}
STAND_IN
# The lines of the steps file of FreeBSD that delete the setting of each service.
sysrc_lines="$(printf '%s\n' 'sysrc -x splicefsd_enable' 'sysrc -x splicefs_enable')"
# What every case starts from: only the server is built (v1.2.3, and its record names 1.2.2 as the
# published version; the client is v1.4.0 and its record names 1.3.9), no call fails, no file
# changes, and the system is of the format deb.
scenario() {
    built="server"
    record=1.2.2
    client_record=1.3.9
    fail_on=
    reinstalled="/etc/a"
    first="/etc/a"
    last="/etc/a"
    cores=
    late_cores=
    user=splicefs
    firewalld=
    zones=
    port_open=
    format=deb
    fetch_hook=
    fetched_server=
    fetched_client=
    removal_lines_added=
}

# Runs the case $1 with the settings of scenario: $built names the programs whose packages are in
# dist, the snapshot of step 0 is $first, the snapshot of step 9 is $last, the one after each reinstall
# is $reinstalled, $cores are the cores listed at the fourth look (before step 3 of a run of the
# server alone), $late_cores those listed at the look after the last snapshot, $user is the user the
# service runs as, $format the package format of the system ($removal_lines_added, when not empty, is
# added to the end of the steps file of the documented removal, as the file of FreeBSD has lines the
# others do not). $firewalld, when not empty, makes the
# system run firewalld ($fetch_hook, when not empty, gives the system a hook that fetches the published
# package itself; $fetched_server and $fetched_client, when not empty, are the versions of the files it
# fetches, which the site may have listed later than the host read it, else they are the host's), and $zones names the zone files it has before the test (public.xml and
# public.xml.old, or neither); $port_open makes the port stay open in it. A call that holds the text
# in $fail_on fails. The first phase runs, then the restart the host does (a service that is not
# enabled does not come back), then the second phase, unless the first failed. Keeps the log of the
# steps in $t/cases/$1/out/log, the result in $t/cases/$1/out/result, the calls in
# $t/cases/$1/dir/log and the status of the last phase in $t/cases/$1/status; the cases are read
# with use_case, after wait.
launch() {
    case_dir="$t/cases/$1"
    mkdir -p "$case_dir/dir" "$case_dir/root/dist" "$case_dir/baselines"
    ln -s "$t/farm/scripts" "$t/farm/programs" "$t/farm/keys" "$case_dir/root/"
    if [ -n "$removal_lines_added" ]; then
        cp -R "$root/steps" "$case_dir/root/steps"
        printf '%s\n' "$removal_lines_added" >>"$case_dir/root/steps/uninstall-apt.sh"
    else
        ln -s "$t/farm/steps" "$case_dir/root/"
    fi
    # The snapshots are taken in step 0, twice around the reinstall of each program built, and in step 9.
    printf '%s\n' "$first" >"$case_dir/dir/snapshot.1"
    taken=1
    for program in $built; do
        mkdir -p "$case_dir/root/dist/$program"
        case "$program" in
            server) printf 'VERSION=v1.2.3\nPACKAGE_DATE=20261112\nUPGRADE_FROM=%s\n' "$record" ;;
            *) printf 'VERSION=v1.4.0\nPACKAGE_DATE=20261113\nUPGRADE_FROM=%s\n' "$client_record" ;;
        esac >"$case_dir/root/dist/$program/version"
        case "$program:$record:$client_record" in
            server:none:* | client:*:none) : >"$case_dir/baselines/$program" ;;
            server:*) printf '%s\n' "$record" >"$case_dir/baselines/$program" ;;
            *) printf '%s\n' "$client_record" >"$case_dir/baselines/$program" ;;
        esac
        printf '%s\n' "$first" >"$case_dir/dir/snapshot.$((taken + 1))"
        printf '%s\n' "$reinstalled" >"$case_dir/dir/snapshot.$((taken + 2))"
        taken=$((taken + 2))
    done
    printf '%s\n' "$last" >"$case_dir/dir/snapshot.$((taken + 1))"
    [ -z "$cores" ] || printf '%s\n' "$cores" >"$case_dir/dir/cores.4"
    [ -z "$late_cores" ] || printf '%s\n' "$late_cores" >"$case_dir/dir/cores.after-snapshot"
    echo "$((taken + 1))" >"$case_dir/dir/last-snapshot"
    # Bytes a copy by line would change: a carriage return and no newline at the end.
    mkdir -p "$case_dir/dir/zones-initial"
    for zone in $zones; do printf 'zone %s\r\nas shipped' "$zone" >"$case_dir/dir/zones-initial/$zone"; done
    (
        status=0
        export STAND_IN_FAIL="$fail_on" STAND_IN_DIR="$case_dir/dir" STAND_IN_USER="$user" \
            STAND_IN_FIREWALLD="$firewalld" STAND_IN_PORT_OPEN="$port_open" STAND_IN_FETCH="$fetch_hook" \
            STAND_IN_FETCHED_SERVER="$fetched_server" STAND_IN_FETCHED_CLIENT="$fetched_client" \
            FORMAT="$format" PLATFORM=linux/amd64 PROGRAMS="$built" PACKAGE_TEST_OUT="$case_dir/out" BASELINES="$case_dir/baselines"
        steps="$case_dir/root/scripts/package-test-steps.sh"
        sh "$steps" phase1 || status=$?
        if [ "$status" -eq 0 ]; then
            # The host restarts the system between the phases: what is not enabled does not come back.
            echo "the system is restarted" >>"$case_dir/dir/log"
            [ -f "$case_dir/dir/enabled" ] || rm -f "$case_dir/dir/active"
            sh "$steps" phase2 || status=$?
        fi
        if [ "$status" -eq 0 ]; then
            sh "$steps" phase3 || status=$?
        fi
        echo "$status" >"$case_dir/status"
    ) &
}

# Points the checks that follow at the case $1: $out (the log of the steps), $dir, $result and
# $status.
use_case() {
    out="$t/cases/$1/out/log"
    dir="$t/cases/$1/dir"
    result="$(cat "$t/cases/$1/out/result" 2>/dev/null || echo "no result")"
    read -r status <"$t/cases/$1/status"
}

# The lines of the output that start with the texts named by the arguments are in that order.
lines_in_order() {
    previous=0
    for start in "$@"; do
        n="$(grep -n -F -e "$start" "$out" | grep -m 1 "^[0-9]*:$start" | cut -d: -f1)"
        [ -n "$n" ] && [ "$n" -gt "$previous" ] || return 1
        previous="$n"
    done
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
# The result of the run is the line of the step $1, which failed.
failed_in() {
    case "$result" in "step $1:"*) return 0 ;; *) return 1 ;; esac
}
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
# The line $2 of the output, which names a core dump, comes after the first line $1 of the
# difference between the snapshots, so that the core is named next to the difference.
named_after_the_difference() {
    difference="$(grep -n -F -e "$1" "$out" | head -n 1 | cut -d: -f1)"
    named="$(grep -n -F -e "$2" "$out" | tail -n 1 | cut -d: -f1)"
    [ -n "$difference" ] && [ -n "$named" ] && [ "$named" -gt "$difference" ]
}
# The cores of the system are looked for again after the last snapshot.
cores_looked_for_after_the_last_snapshot() {
    looked="$(last_line_of core-files.sh)"
    snapshot="$(last_line_of lifecycle-snapshot.sh)"
    [ "$looked" -gt "$snapshot" ]
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
zones_as_they_were() { diff -r "$dir/zones-initial" "$dir/zones" >/dev/null; }
steps_run() {
    # The line that says the removal command is left out starts like a step and is no step.
    steps_seen="$(grep '^step ' "$out" | cut -c1-7 | uniq | tr '\n' ' ')"
    [ "$steps_seen" = "$1" ]
}
failed_status() { [ "$status" -ne 0 ]; }
passed_status() { [ "$status" -eq 0 ] && [ "$result" = ok ]; }

# The published rpm is installed by the package manager after the key was imported, and the line of
# that install holds no flag that switches the check off.
published_rpm_checked() {
    imported="$(line_of 'rpm --import /keys/splicefs.asc')"
    installed="$(line_of 'dnf install -y -q --setopt=localpkg_gpgcheck=1 /pkg/server/published/')"
    [ "$imported" -gt 0 ] && [ "$installed" -gt "$imported" ] &&
        ! grep -F '/pkg/server/published/' "$dir/log" | grep -q -e nogpgcheck -e allow-unsigned -e allow-untrusted -e 'rpm -i'
}
# The published apk is installed after the key of the site was put in place, with no flag that
# switches the check off, and the key is gone before the new package is put over it.
published_apk_checked() {
    placed="$(line_of 'cp /keys/splicefs.rsa.pub /etc/apk/keys/')"
    installed="$(line_of 'apk add -q /pkg/server/published/')"
    removed="$(line_of 'rm -f /etc/apk/keys/splicefs.rsa.pub')"
    new_package="$(line_of 'sh apk v1.2.2 v1.2.3 file')"
    [ "$placed" -gt 0 ] && [ "$installed" -gt "$placed" ] && [ "$removed" -gt "$installed" ] && [ "$new_package" -gt "$removed" ] &&
        ! grep -F '/pkg/server/published/' "$dir/log" | grep -q -e allow-untrusted -e nogpgcheck
}

# Every case runs at the same time, because each is a process that starts a few hundred more.
scenario; launch good
scenario; record=1.2.3; launch same_version
scenario; record=none; launch nothing_published
scenario; fail_on=check_links; launch file_check_fails
scenario; fail_on="apt-get install"; launch baseline_install_fails
scenario; record=none; fail_on="apt-get install"; launch install_fails
scenario; fail_on="sh deb v1.2.2 v1.2.3"; launch upgrade_fails
scenario; fail_on="verify_markers_kept upgrade"; launch upgrade_loses_files
scenario; reinstalled="/etc/changed"; launch reinstall_changes_files
scenario; fail_on="verify_markers_kept reinstall"; launch reinstall_loses_files
scenario; format=rpm; launch rpm_holds_nothing
scenario; format=apk; launch apk_holds_nothing
scenario; fail_on="systemctl enable"; launch enable_fails
scenario; fail_on=write_test_config; launch test_config_not_written
scenario; fail_on=check_test_config; launch test_config_not_where_documented
scenario; fail_on="systemctl start"; launch start_fails
scenario; user=root; launch runs_as_root
scenario; fail_on="systemctl restart"; launch restart_fails
scenario; fail_on=readlink; launch process_left_after_stop
scenario; fail_on="systemctl disable"; launch disable_fails
scenario; fail_on="apt-get remove"; launch plain_removal_fails
scenario; fail_on="verify_markers_kept plain removal"; launch plain_removal_takes_files
scenario; fail_on=check_programs_removed; launch plain_removal_keeps_program
scenario; last="/etc/b"; launch snapshot_differs
scenario; cores="/core pid 7 program splicefsd: /usr/bin/splicefsd"; launch core_dump
scenario; cores="/core.7 pid 7 program splicefsd: /usr/bin/splicefsd"; last="$(printf '/etc/a\n/core.7')"; launch core_named_by_a_step
scenario; late_cores="/core.9 pid 9 program splicefsd: /usr/bin/splicefsd"; last="$(printf '/etc/a\n/core.9')"; launch core_after_the_snapshot
scenario; last="$(printf '/etc/a\n/core.5')"; launch core_no_step_could_read
scenario; last="$(printf '/etc/a\n0123abcd  /etc/core.conf')"; launch checksum_of_a_core_named_file
scenario; built=client; launch client_only
scenario; built="server client"; launch both
scenario; built="server client"; format=rpm; launch both_rpm
scenario; built="server client"; format=apk; launch both_apk
scenario; built="server client"; fail_on="apt-get install -y -qq /pkg/client/published"; launch client_baseline_fails
scenario; built="server client"; fail_on="sh deb v1.3.9 v1.4.0"; launch client_upgrade_fails
scenario; built="server client"; fail_on="apt-get remove -y -qq splicefs-client"; launch client_plain_removal_fails
scenario; built="server client"; last="/etc/b"; launch both_snapshot_differs
scenario; removal_lines_added="$sysrc_lines"; launch service_lines_server_only
scenario; removal_lines_added="$sysrc_lines"; built=client; launch service_lines_client_only
scenario; fetch_hook=1; launch hook_fetches
scenario; fetch_hook=1; record=none; launch hook_nothing_published
scenario; fetch_hook=1; fail_on=fetch_published_package; launch hook_fails
scenario; fetch_hook=1; built="server client"; launch hook_both
scenario; fetch_hook=1; record=1.2.1; fetched_server=1.2.2; launch hook_fetches_newer
scenario; fetch_hook=1; record=1.2.1; fetched_server=1.2.3; launch hook_fetches_the_new_version
scenario; fetch_hook=1; fail_on=published_baseline_version; launch hook_version_unreadable
scenario; fetch_hook=1; record=1.2.1; fetched_server=1.2.4; launch hook_fetches_a_newer_release
scenario; record=1.2.4; launch recorded_newer_release
scenario; built="server client"; fetch_hook=1; client_record=1.3.0; fetched_client=1.4.1; launch client_fetches_a_newer_release
scenario; fetch_hook=1; built="server client"; record=1.2.1; client_record=1.3.0; fetched_server=1.2.2; fetched_client=1.3.9; launch hook_both_newer
scenario; format=rpm; firewalld=1; zones="public.xml public.xml.old"; launch zones_existed
scenario; format=rpm; firewalld=1; launch zones_missing
scenario; format=rpm; firewalld=1; zones="public.xml.old"; launch one_zone_existed
scenario; format=rpm; firewalld=1; port_open=1; launch port_stays_open
scenario; format=rpm; firewalld=1; zones="public.xml public.xml.old"; fail_on="firewall-zones/public.xml.old"; launch zone_not_saved
wait

use_case good
expect "a good run passes" passed_status
expect "the steps run in order: 0, 1, 2, 3, 4, 5, 7, 8, 9" \
    steps_run 'step 0: step 1: step 2: step 3: step 4: step 5: step 7: step 8: step 9: '
expect "the key is in place for the install of the published file only" \
    in_order "install -m 0644 /keys/splicefs.asc /etc/apt/keyrings/splicefs.asc" "apt-get install -y -qq /pkg/server/published/" "rm -f /etc/apt/keyrings/splicefs.asc"
expect "the first snapshot is taken before the published package is installed" \
    in_order lifecycle-snapshot.sh "apt-get install -y -qq /pkg/server/published/splicefs-server_1.2.2_amd64.deb"
expect "the new file goes over the published one, then over itself, then the plain removal, then the documented" \
    in_order "apt-get install -y -qq /pkg/server/published/" \
    "sh deb v1.2.2 v1.2.3 file /pkg/server/splicefs-server_1.2.3_amd64.deb" \
    "sh deb v1.2.3 v1.2.3 file /pkg/server/splicefs-server_1.2.3_amd64.deb" \
    "apt-get remove" "apt-get purge"
expect "the service is enabled, configured, started, restarted, the container restarted, stopped, disabled, then removed" \
    in_order "systemctl enable" write_test_config "systemctl start" "systemctl restart" "the system is restarted" \
    "systemctl stop" "systemctl disable" "apt-get remove" "apt-get purge"
expect "the test configuration is checked where the documentation says before the service starts" \
    in_order write_test_config check_test_config "systemctl start"
expect "the service runs as its own user" holds "ok: runs as splicefs"
expect "the health endpoint answers from inside, and the line says so" holds "ok: answers 200 on /api/v1/health from inside"
expect "no line of the steps says from outside: only the host asks from outside" sh -c "! grep -q 'from outside' '$out'"
expect "the service is active and answering after a restart" holds "ok: active and answering after a restart"
expect "the service is active and answering after the container restarts, because it is enabled" \
    holds "ok: active and answering after a reboot, because it was enabled"
expect "after the stop the service is silent and nothing of ours runs" holds "ok: stopped and silent"
expect "after the stop no process of ours is left" holds "ok: no process of ours is running after the stop"
expect "after the disable the service is not enabled" holds "ok: the service is not enabled"
expect "the test data is removed after the documented removal, before the last snapshot" test_data_removed_before_the_last_snapshot
expect "a system without firewalld has nothing changed in its firewall" \
    sh -c "! grep -q -e '--add-port' -e '--reload' -e 'cp /etc/firewalld' '$dir/log'"
expect "the removals fall between the first and the last snapshot" four_snapshots_around_the_removals
expect "the package file is not installed again between the plain removal and the documented removal" \
    no_install_after_the_plain_removal_of 'apt-get install' 'apt-get remove'
expect "the configuration file and the data file are written after the published install, kept by the upgrade" \
    in_order "apt-get install -y -qq /pkg/server/published/" "write_markers deb" "sh deb v1.2.2 v1.2.3" "verify_markers_kept upgrade"
expect "the plain removal checks the configuration and the data remain" sh -c "grep -q 'verify_markers_kept plain removal' '$dir/log'"
expect "the install is of the package file under /pkg" sh -c "grep -q 'file /pkg/server/splicefs-server_' '$dir/log'"
expect "no setup script and no repository are used" sh -c "! grep -q 'setup.sh\|apt-key\|sources.list' '$dir/log'"
expect "the setup script's removal is not run" sh -c "! grep -q 'splicefs-setup.sh' '$dir/log'"
expect "the documented removal traces its commands, so the log names the one that failed" \
    sh -c "grep -q \"sh -c set -ex\" '$dir/log'"
expect "the documented removal names the package the package manager still holds (dpkg keeps its configuration)" \
    sh -c "grep -q 'apt-get purge splicefs-server' '$dir/log'"
expect "the documented removal leaves out the program that is not held" sh -c "! grep -q 'apt-get purge.*splicefs-client' '$dir/log'"
expect "the package manager is asked what it holds, once for each program" sh -c "[ \"\$(grep -c 'package_held' '$dir/log')\" -eq 2 ]"
expect "a removal command with names does not say it is left out" lacks "the removal command is left out"
expect "every other line of the steps file runs as written" \
    sh -c "grep -q 'apt-get autoremove --purge' '$dir/log' && grep -q 'userdel splicefs' '$dir/log'"
expect "the service steps are those of the server" holds "step 3: server: "

use_case rpm_holds_nothing
expect "an rpm run passes" passed_status
expect "the published rpm is installed with the key imported first, and no flag that skips the check" \
    published_rpm_checked
expect "the documented removal says its removal command is left out, with the format" \
    holds "step 9: rpm: nothing installed, the removal command is left out, as the steps say"
expect "the removal command is not run again after the plain removal" sh -c "[ \"\$(grep -c 'dnf remove' '$dir/log')\" -eq 1 ]"
expect "every other line of the steps file runs as written" \
    sh -c "grep -q 'dnf autoremove' '$dir/log' && grep -q 'userdel splicefs' '$dir/log'"
expect "the package file is not installed again" no_install_after_the_plain_removal_of 'dnf install' 'dnf remove'

use_case apk_holds_nothing
expect "an apk run passes" passed_status
expect "the published apk is installed with the site's key in place for that install only, and no flag that skips the check" \
    published_apk_checked
expect "the documented removal says its removal command is left out, with the format" \
    holds "step 9: apk: nothing installed, the removal command is left out, as the steps say"
expect "the removal command is not run again after the plain removal" sh -c "[ \"\$(grep -c 'apk del' '$dir/log')\" -eq 1 ]"
expect "every other line of the steps file runs as written" \
    sh -c "grep -q 'deluser splicefs' '$dir/log' && grep -q 'rm -rf /var/lib/splicefs' '$dir/log'"
expect "the package file is not installed again" no_install_after_the_plain_removal_of 'apk add' 'apk del'

use_case same_version
expect "a published file of the same version passes" passed_status
expect "the same version is put over the published one with the reinstall, and again over itself" \
    sh -c "[ \"\$(grep -c 'sh deb v1.2.3 v1.2.3 file' '$dir/log')\" -eq 2 ]"

use_case nothing_published
expect "a run with nothing published passes" passed_status
expect "the steps run in order with nothing published" \
    steps_run 'step 0: step 1: step 2: step 3: step 4: step 5: step 7: step 8: step 9: '
expect "step 1 says nothing is published" holds "nothing is published for server"
expect "no published file is installed" sh -c "! grep -q '/published/' '$dir/log'"
expect "the new file is installed, and the configuration file and the data file are written" \
    in_order "apt-get install -y -qq /pkg/server/splicefs-server_1.2.3_amd64.deb" "write_markers deb" "sh deb v1.2.3 v1.2.3 file"

# The hook of a system the host cannot reach (the FreeBSD machine): the published package is the file it
# fetched, not the one in /pkg.
use_case hook_fetches
expect "a run whose system fetches the published package itself passes" passed_status
expect "the hook is asked once, for the system, before the published file is installed" \
    sh -c "[ \"\$(grep -c fetch_published_package '$dir/log')\" -eq 1 ]"
expect "the file the hook fetched is installed as the published package" \
    in_order "fetch_published_package system" "apt-get install -y -qq /fetched/server/splicefs-server-published.deb"
expect "the file of the host is not used" sh -c "! grep -q '/pkg/server/published/' '$dir/log'"
expect "the new file goes over the fetched one" in_order "apt-get install -y -qq /fetched/server/" "sh deb v1.2.2 v1.2.3 file"

use_case hook_nothing_published
expect "a run with nothing published and a hook passes" passed_status
expect "nothing published asks no hook: there is nothing to fetch" sh -c "! grep -q fetch_published_package '$dir/log'"
expect "step 1 says nothing is published, with a hook as without" holds "nothing is published for server"

use_case hook_fails
expect "a hook that fails fails step 1" failed_in 1
expect "the failure of the hook is named" holds "fetching the published package failed"
expect "nothing is installed after a failed fetch" sh -c "! grep -q 'apt-get install' '$dir/log'"

# The site listed a newer package when the system fetched than when the host read it (the host read
# 1.2.1, the file is 1.2.2): everything that needs the version of the published package, the check of
# what the installed program reports and the decision of step 2 to upgrade or reinstall, has the
# version of the file, read once, and the host's is not used.
use_case hook_fetches_newer
expect "a run whose published package is newer than the host read passes" passed_status
expect "the version is read from the fetched file, after the fetch and before the install" \
    in_order "fetch_published_package system" "published_baseline_version system /fetched/server/splicefs-server-published.deb" \
    "apt-get install -y -qq /fetched/server/splicefs-server-published.deb"
expect "the version is read once" sh -c "[ \"\$(grep -c published_baseline_version '$dir/log')\" -eq 1 ]"
expect "step 1 says the version of the fetched file is installed" holds "ok: the published v1.2.2 is installed"
expect "the installed program is asked for the version of the fetched file" \
    sh -c "grep -q 'grep -qF .\$2. sh splicefsd v1.2.2' '$dir/log'"
expect "the new file goes over the version of the fetched file" in_order "apt-get install -y -qq /fetched/server/" "sh deb v1.2.2 v1.2.3 file"
expect "the version the host read is not used by any call" sh -c "! grep -q 'v1.2.1' '$dir/log'"

use_case hook_fetches_the_new_version
expect "a run whose fetched package is the version of the new one passes" passed_status
expect "the same version is put over the fetched one with the reinstall, and again over itself" \
    sh -c "[ \"\$(grep -c 'sh deb v1.2.3 v1.2.3 file' '$dir/log')\" -eq 2 ]"
expect "no call upgrades from the version the host read" sh -c "! grep -q 'v1.2.1' '$dir/log'"

# A release published during the run is what the system fetches (the site lists the newest), and it is
# newer than the package under test (v1.2.3): step 2 would go down. It never does: it refuses, with the
# line that says what happened, before the new file is put anywhere.
use_case hook_fetches_a_newer_release
expect "a published package newer than the package under test fails step 2" failed_in 2
expect "the refusal names the program, both versions and what to do" \
    holds "step 2: server: the published v1.2.4 is newer than the package under test v1.2.3; a newer release was published during this run, run it again"
expect "the new file is not put over the newer one" sh -c "! grep -q 'sh deb v1.2.4 v1.2.3 file' '$dir/log'"
expect "nothing is installed after the refusal but the published file" sh -c "[ \"\$(grep -c 'apt-get install' '$dir/log')\" -eq 1 ]"
expect "that stops the run: no step 3" lacks "step 3:"

# The same on a system the host reaches, when the version it recorded is newer than the package (a
# build by hand that recorded the newest of the site, long after it built the package).
use_case recorded_newer_release
expect "a recorded baseline newer than the package under test fails step 2" failed_in 2
expect "the refusal is the same line" \
    holds "step 2: server: the published v1.2.4 is newer than the package under test v1.2.3; a newer release was published during this run, run it again"

# Only the program whose published package is newer is refused, and it is named: the server passes
# step 2 and the client does not.
use_case client_fetches_a_newer_release
expect "a newer published client fails step 2" failed_in 2
expect "the refusal names the client and its versions" \
    holds "step 2: client: the published v1.4.1 is newer than the package under test v1.4.0; a newer release was published during this run, run it again"
expect "the server went through step 2 before it" holds "step 2: server: the new package file is installed over it, and over itself"

use_case hook_version_unreadable
expect "a hook that cannot read the version fails step 1" failed_in 1
expect "the failure of the read is named" holds "reading the version of the fetched package failed"
expect "nothing is installed when the version is not known" sh -c "! grep -q 'apt-get install' '$dir/log'"

use_case hook_both_newer
expect "a run of both programs, each with a published package newer than the host read, passes" passed_status
expect "each program is upgraded from the version of its own fetched file" \
    in_order "sh deb v1.2.2 v1.2.3 file" "sh deb v1.3.9 v1.4.0 file"
expect "the version is read once for each program" sh -c "[ \"\$(grep -c published_baseline_version '$dir/log')\" -eq 2 ]"
expect "no call names a version the host read" sh -c "! grep -q 'v1.2.1' '$dir/log' && ! grep -q 'v1.3.0' '$dir/log'"

use_case hook_both
expect "a run of both programs whose system fetches the published packages passes" passed_status
expect "the hook is asked for the server and then for the client, and each file is installed as fetched" \
    in_order "fetch_published_package system" "apt-get install -y -qq /fetched/server/splicefs-server-published.deb" \
    "apt-get install -y -qq /fetched/client/splicefs-client-published.deb"
expect "the hook is asked once for each program" sh -c "[ \"\$(grep -c fetch_published_package '$dir/log')\" -eq 2 ]"

use_case file_check_fails
expect "a failing file check fails the system" failed_status
expect "the failing step is named" failed_in 2
expect "a failing check stops the run: no step 9" lacks "step 9:"
expect "a failing check stops the run: no removal" sh -c "! grep -q 'apt-get purge' '$dir/log'"

use_case baseline_install_fails
expect "a failing install of the published file is step 1" failed_in 1
use_case install_fails
expect "a failing install with no published file is step 2" failed_in 2

use_case upgrade_fails
expect "a failing upgrade is step 2" failed_in 2
expect "a failing upgrade is named" holds "putting the new package over the published one failed"

use_case upgrade_loses_files
expect "an upgrade that loses the configuration or the data fails step 2" failed_in 2

use_case reinstall_changes_files
expect "a file that changes when the package is installed over itself fails step 2" failed_in 2
expect "the change is shown" holds "/etc/changed"

use_case reinstall_loses_files
expect "a reinstall that loses the configuration or the data fails step 2" failed_in 2

use_case enable_fails
expect "a failing enable command is step 3" failed_in 3
expect "that stops the run: no start" lacks "step 4:"
use_case test_config_not_written
expect "a test configuration that cannot be written is step 3" failed_in 3
expect "that stops the run: no start" lacks "step 4:"
use_case test_config_not_where_documented
expect "a test configuration not where the documentation says is step 3" failed_in 3
use_case start_fails
expect "a failing start command is step 4" failed_in 4
expect "that stops the run: no restart" lacks "step 5:"
use_case runs_as_root
expect "a service that runs as another user fails step 4" failed_in 4
expect "the user is named" holds "the service runs as 'root', not as 'splicefs'"
use_case restart_fails
expect "a failing restart is step 5" failed_in 5
use_case process_left_after_stop
expect "a process of ours left after the stop is step 7" failed_in 7
expect "that stops the run: no disable" lacks "step 8:"
use_case disable_fails
expect "a failing disable command is step 8" failed_in 8
expect "that stops the run: no removal" sh -c "! grep -q 'apt-get remove' '$dir/log'"

use_case plain_removal_fails
expect "a failing plain removal fails step 9" failed_in 9
expect "a failing plain removal stops the run: no documented removal" sh -c "! grep -q 'apt-get purge' '$dir/log'"

use_case plain_removal_takes_files
expect "a plain removal that takes the configuration or the data fails step 9" failed_in 9
expect "that stops the run: no documented removal" sh -c "! grep -q 'apt-get purge' '$dir/log'"

use_case plain_removal_keeps_program
expect "a program left behind by the plain removal fails step 9" holds "the plain removal left a program"

use_case snapshot_differs
expect "a snapshot that differs fails step 9" failed_in 9
expect "the difference is shown" holds "/etc/b"
expect "a difference with no core in it names no core" lacks "core dump"
expect "the cores are looked for again after the last snapshot" cores_looked_for_after_the_last_snapshot

use_case core_dump
expect "a core dump is named with the step before which it was found" holds "core dump after step 2: server: /core pid 7"

use_case core_named_by_a_step
expect "a core in the difference fails step 9" failed_in 9
expect "the core in the difference is named next to it, with the step that found it" \
    named_after_the_difference "> /core.7" "core dump after step 2: server: /core.7 pid 7 program splicefsd: /usr/bin/splicefsd"
expect "a core a step named is not looked at again" sh -c "! grep -q 'core-files.sh /' '$dir/log'"

use_case core_after_the_snapshot
expect "a core that appears after the last snapshot is named by the look after it" \
    holds "core dump after step 9: /core.9 pid 9 program splicefsd: /usr/bin/splicefsd"
expect "and it is named next to the difference" \
    named_after_the_difference "> /core.9" "core dump after step 9: /core.9 pid 9 program splicefsd"

use_case core_no_step_could_read
expect "a core that no step named fails step 9" failed_in 9
expect "it is looked at by its path" sh -c "grep -q 'core-files.sh /core.5' '$dir/log'"
expect "it is named next to the difference, with what the file is" \
    named_after_the_difference "> /core.5" "core dump no step could read: /core.5: not a 64-bit ELF core with a process note: 40 bytes, starting 177 E L F"

use_case checksum_of_a_core_named_file
expect "the checksum of a file whose name starts with core is no path of a core" sh -c "! grep -q 'core-files.sh /' '$dir/log'"

# Both programs in one boot: each step runs for the server, then for the client. The service steps are
# built for the server only; the client says they wait and nothing is done for it.
use_case both
expect "a run of both programs passes" passed_status
expect "the steps run in order, each once for the boot" \
    steps_run 'step 0: step 1: step 2: step 3: step 4: step 5: step 7: step 8: step 9: '
expect "neither program is left out" lacks "no packages, left out"
expect "the baseline and the new package are put in for the server, then for the client" \
    in_order "apt-get install -y -qq /pkg/server/published/splicefs-server_1.2.2_amd64.deb" \
    "apt-get install -y -qq /pkg/client/published/splicefs-client_1.3.9_amd64.deb" \
    "sh deb v1.2.2 v1.2.3 file /pkg/server/splicefs-server_1.2.3_amd64.deb" \
    "sh deb v1.3.9 v1.4.0 file /pkg/client/splicefs-client_1.4.0_amd64.deb"
expect "each program is installed over itself: the server and the client, each with its own version" \
    in_order "sh deb v1.2.3 v1.2.3 file /pkg/server/splicefs-server_1.2.3_amd64.deb" \
    "sh deb v1.4.0 v1.4.0 file /pkg/client/splicefs-client_1.4.0_amd64.deb"
expect "the client's own file checks run" sh -c "[ \"\$(grep -c 'check_extras' '$dir/log')\" -eq 4 ]"
expect "each step runs for the server, then for the client" \
    lines_in_order "step 1: server: " "step 1: client: " "step 2: server: " "step 2: client: " \
    "step 3: server: " "step 3: client: " "step 4: server: " "step 4: client: " "step 9: server: the package" \
    "step 9: client: the package" "step 9: the documented removal" "step 9: server: what" "step 9: client: what" \
    "step 9: the system is as it was"
expect "the service steps of the client wait for its certificate trust setting" \
    sh -c "for n in 3 4 5 7 8; do grep -qx \"step \$n: client: service steps wait for the client's certificate trust setting\" '$out' || exit 1; done"
expect "the service steps of the server run" \
    sh -c "for n in 3 4 5 7 8; do grep -q \"^step \$n: server: \" '$out' || exit 1; done"
expect "the service of the client is never enabled, started, restarted, stopped or disabled" \
    sh -c "! grep -q -e 'systemctl [a-z]* splicefs.service' -e 'systemctl [a-z]* --now splicefs.service' '$dir/log'"
expect "a test configuration is written once, for the server" sh -c "[ \"\$(grep -c 'write_test_config' '$dir/log')\" -eq 1 ]"
expect "six snapshots: the boot, around the reinstall of each program, and the end" \
    sh -c "[ \"\$(grep -c 'lifecycle-snapshot.sh' '$dir/log')\" -eq 6 ]"
expect "the plain removal of the server, then of the client, then one documented removal" \
    in_order "apt-get remove -y -qq splicefs-server" "apt-get remove -y -qq splicefs-client" "apt-get purge"
expect "the documented removal names both programs, in one command" \
    sh -c "[ \"\$(grep -c 'apt-get purge' '$dir/log')\" -eq 1 ] && grep -q 'apt-get purge splicefs-server splicefs-client' '$dir/log'"
expect "the test data is removed once" sh -c "[ \"\$(grep -c 'remove_test_data' '$dir/log')\" -eq 1 ]"

use_case client_only
expect "a run of the client alone passes" passed_status
expect "the steps run in order" steps_run 'step 0: step 1: step 2: step 3: step 4: step 5: step 7: step 8: step 9: '
expect "the client's service steps wait" \
    sh -c "for n in 3 4 5 7 8; do grep -qx \"step \$n: client: service steps wait for the client's certificate trust setting\" '$out' || exit 1; done"
expect "nothing is configured, started or stopped" \
    sh -c "! grep -q -e 'write_test_config' -e 'systemctl enable' -e 'systemctl start' -e 'systemctl stop' '$dir/log'"
expect "the published client file is installed, then the new one" \
    in_order "apt-get install -y -qq /pkg/client/published/splicefs-client_1.3.9_amd64.deb" \
    "sh deb v1.3.9 v1.4.0 file /pkg/client/splicefs-client_1.4.0_amd64.deb"
expect "the documented removal names the client only" \
    sh -c "grep -q 'apt-get purge splicefs-client' '$dir/log' && ! grep -q 'apt-get purge.*splicefs-server' '$dir/log'"

# The steps tell a person to leave out the line of a service never turned on; the test does, for
# every service its steps did not turn on (those of steps 3 to 8, which only the server has), and says so.
use_case service_lines_server_only
expect "a run with the lines of the services passes" passed_status
expect "the line of the service that was turned on runs" sh -c "grep -q 'sysrc -x splicefsd_enable' '$dir/log'"
expect "the line of the service that was never turned on does not run" sh -c "! grep -q 'sysrc -x splicefs_enable' '$dir/log'"
expect "the line that is left out is printed" holds 'step 9: deb: "sysrc -x splicefs_enable" is left out, as the steps say'
expect "the line that runs is not printed as left out" lacks '"sysrc -x splicefsd_enable" is left out'

use_case service_lines_client_only
expect "a run of the client alone passes" passed_status
expect "neither line runs: its service steps wait" sh -c "! grep -q 'sysrc -x' '$dir/log'"
expect "both lines are printed as left out" \
    sh -c "grep -q '\"sysrc -x splicefs_enable\" is left out' '$out' && grep -q '\"sysrc -x splicefsd_enable\" is left out' '$out'"

use_case both_rpm
expect "both programs pass on an rpm system" passed_status
expect "each program is removed once, and the documented removal has no command left" \
    sh -c "[ \"\$(grep -c 'dnf remove' '$dir/log')\" -eq 2 ]"
expect "the documented removal says its removal command is left out" \
    holds "step 9: rpm: nothing installed, the removal command is left out, as the steps say"

use_case both_apk
expect "both programs pass on an apk system" passed_status
expect "each program is removed once, and the documented removal has no command left" \
    sh -c "[ \"\$(grep -c 'apk del' '$dir/log')\" -eq 2 ]"

use_case client_baseline_fails
expect "a failing install of the client's published file is step 1" failed_in 1
expect "the step names the client" holds "step 1: client: "
expect "that stops the run: no step 2" lacks "step 2:"

use_case client_upgrade_fails
expect "a failing upgrade of the client is step 2" failed_in 2
expect "the server's step 2 ran first" sh -c "grep -q '^step 2: server: ' '$out' && grep -q '^step 2: client: ' '$out'"
expect "that stops the run: no step 3" lacks "step 3:"

use_case client_plain_removal_fails
expect "a failing plain removal of the client is step 9" failed_in 9
expect "that stops the run: no documented removal" sh -c "! grep -q 'apt-get purge' '$dir/log'"

use_case both_snapshot_differs
expect "a snapshot that differs after both are removed fails step 9" failed_in 9

# Step 4 opens the port in the firewall and changes zone files that did not exist before; step 9 puts
# each file back as it was, or deletes it when it was not there.
use_case zones_existed
expect "a run on a system with firewalld passes" passed_status
expect "the zone files are saved, the port opened, and the saved files put back before the last snapshot" \
    firewall_zones_saved_then_put_back_by 'firewall-zones/public.xml /etc/firewalld/zones/public.xml'
expect "both zone files are put back" sh -c "grep -q 'firewall-zones/public.xml.old /etc/firewalld/zones/public.xml.old' '$dir/log'"
expect "the zone files are as they were, byte for byte" zones_as_they_were
expect "no zone file is deleted when it existed" sh -c "! grep -q 'rm -f /etc/firewalld' '$dir/log'"

use_case zones_missing
expect "a run on a system with firewalld and no zone files passes" passed_status
expect "the missing zone files are deleted after the removals, before the last snapshot" \
    firewall_zones_saved_then_put_back_by 'rm -f /etc/firewalld/zones/public.xml.old'
expect "both zone files are deleted" sh -c "grep -q 'rm -f /etc/firewalld/zones/public.xml\$' '$dir/log'"
expect "no zone file is left that was not there" zones_as_they_were
expect "nothing is copied back into the system" sh -c "! grep -q 'firewall-zones/public.xml.* /etc/firewalld/zones/' '$dir/log'"

use_case one_zone_existed
expect "a run where one zone file existed passes" passed_status
expect "the file that existed is put back and the file that did not is deleted" \
    sh -c "grep -q 'firewall-zones/public.xml.old /etc/firewalld/zones/public.xml.old' '$dir/log' && grep -q 'rm -f /etc/firewalld/zones/public.xml\$' '$dir/log'"
expect "a file that existed is not deleted" sh -c "! grep -q 'rm -f /etc/firewalld/zones/public.xml.old' '$dir/log'"
expect "the zone files are as they were" zones_as_they_were

use_case port_stays_open
expect "a port that is still open after the zone files are put back fails the run" failed_status
expect "that is step 9" failed_in 9
expect "the open port is named" holds "the port 8480 is still open in the firewall"

use_case zone_not_saved
expect "a zone file that cannot be saved fails step 4" failed_in 4
expect "the port is not opened before the zone files are saved" sh -c "! grep -q -e '--add-port' '$dir/log'"

if [ "$failed" -ne 0 ]; then
    echo "$failed package-test-steps case(s) failed"
    exit 1
fi
echo "package-test-steps: all cases as expected"
