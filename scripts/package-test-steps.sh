#!/bin/sh
# check-not-run: runs inside a system the packages are installed in (scripts/package-test.sh starts it in a container)
# The steps of the package test, run INSIDE the system under test, as root, with only what that
# system has: its own /bin/sh (dash, bash or busybox ash), its package manager and its service
# manager. The host (scripts/package-test.sh) boots the system, runs this script as phase 1, asks the
# server from outside, restarts the system, runs phase 2, asks again, runs phase 3 and collects the
# output folder. Outside is by definition not the system, so that question is the host's; the host
# does nothing else to the system, so every step is the same wherever the system runs. Usage:
#   sh scripts/package-test-steps.sh phase1|phase2|phase3
# from a system that has the repository at /src (read only), the package folder of every program
# at /pkg/PROGRAM, the public signing keys at /keys and the baselines at /baselines.
#
# Every program whose packages the host names in PROGRAMS is tested in this one boot, the server first.
# Each phase runs its steps in order, each printed as "step N: PROGRAM: ..." for every program in
# turn, and stops at the first wrong result:
#   0. the file list and the checksums of /etc are written down once (scripts/lifecycle-snapshot.sh);
#   1. the baseline: the previous published package FILE of the program, which the host fetched
#      from the package site and proved by its signed index (scripts/published-verify.sh), is
#      installed with the system's package manager, and a configuration file and a data file are
#      written. The signing key of the project, fetched by the host and proven to be the
#      key of keys/, is given to the package manager as the install page tells a person, and the
#      package manager checks the signature of the file (no flag turns that off; only the new files
#      of step 2, which carry a throwaway signature, skip it). When nothing is published, the step
#      says so and installs nothing. A system the host cannot reach fetches the file itself, and the
#      version of the baseline is the one of the file it got (record_fetched_version);
#   1a. for a program whose service steps are built and that has a published package, its service is
#      enabled, configured and started, the way steps 3 and 4 do it (one set of functions), and its
#      process id and the version its health endpoint reports are written down. With nothing published
#      the step says that the upgrade under a running service is not tested;
#   2. the new package FILE is put over it the way scripts/upgrade-package-lib.sh says (an upgrade,
#      or a reinstall when the version is the same, and a published package newer than the package under
#      test, which a release published during the run makes, fails the step: it never goes down); with no
#      baseline it is installed. Every file the
#      package promises is in its place (scripts/package-test-lib.sh), installing enabled and
#      started nothing (apart from the service step 1a started, which is still enabled and running), and
#      the configuration and data of step 1 are kept. A service step 1a started is checked for the promise of
#      the format (scripts/service-upgrade-lib.sh): deb, rpm and apk restarted it, so it runs in a new
#      process as the new version; on pkg the old process runs as the old version until the restart the
#      upgrade message names, which is then run. Then the file is put
#      over itself once more: the files, the configuration and the state of the service stay as
#      they were;
#   3. the service is enabled with the documented command, and the program's test configuration
#      (programs/PROGRAM/test-config.sh: the server serves one share with one user) is written
#      through the documented folders and found where the documentation says;
#   4. on a system that runs firewalld, the zone files it changes for an open port (public.xml and
#      public.xml.old) are saved, each as a copy or a note that it is missing, and the port of the
#      service is opened; the service is started with the documented command, runs as its own user
#      and does its job (the service check of the program: the server answers its health endpoint
#      from inside, through its own address; the host asks from outside after the phase);
#   5. the service is restarted (phase 1), then the host restarts the system, and the service is
#      active and does its job again, because it is enabled (phase 2);
#   7. the service is stopped: no process of ours is left and the service no longer answers;
#   8. the service is disabled, and is not enabled;
#   9. the package manager's plain removal, program by program: the programs are gone, the
#      configuration and the data remain. Then the documented removal (the file of steps/ for this
#      system, without the setup script's --remove, which belongs to the setup script test), run
#      once as written except that its removal command names only the packages the package manager
#      still holds, all programs in one command (dpkg keeps the configuration of a removed package, so
#      apt-get purge still names it; the other package managers hold nothing, so the command is left
#      out, as the steps tell a person to do; so are the lines that delete the rc.conf setting of a
#      service the steps 3 to 8 did not turn on, as the steps say): the data, the configuration, the
#      user and the group.
#      Then, program by program, the data the test made is removed, the saved zone files are put back
#      byte for byte (a file that did not exist is deleted) and the port is closed in the firewall,
#      and nothing of ours is installed or running; and the snapshot equals the one of step 0, apart
#      from the paths of scripts/lifecycle-excluded.
# On pkg, which prints messages (deb, rpm and apk print none), what the package printed in step 1 (or 2 when
# nothing is published), in step 2 and in step 9 holds its install, upgrade and remove message, as the manifest
# of the package file says (scripts/package-message-lib.sh).
# The numbers are those of the design of the test. The steps 3, 4, 5, 7 and 8 are built for the
# server only: for the client each prints "service steps wait for the client's certificate trust
# setting" and does nothing. Step 6, the modes of the client, is not built yet.
# Phase 1 is the steps 0 to 4 and the restart of the service in step 5; phase 2, after the host
# restarted the system, is the rest of step 5; phase 3 is the steps 7 to 9.
# Before every step and after the snapshot of step 9, the core dumps that appeared since the step
# before are printed with the program that dumped them (scripts/core-files.sh), so a crash names its
# program and its step; a core in the difference of step 9 is named again next to it.
# The log of both phases and the result ("ok", or the line of the step that failed) are written into
# the folder PACKAGE_TEST_OUT, which the host collects; so are the files the phases pass on to each
# other. The folder is on the system's own disk, which a restart keeps, and its path is left out of
# the snapshots (scripts/lifecycle-excluded). Environment: FORMAT (deb, rpm, apk or pkg), PLATFORM
# (linux/amd64 or linux/arm64), PROGRAMS (the programs to test, in order) and PACKAGE_TEST_OUT.
#
# What differs between package formats is in scripts/service-test-<format>.sh (install_package,
# service_file, the service functions) and scripts/package-test-<format>.sh (package_installed,
# uninstall_file); what the service of the program does is in its service-check.sh. None of them
# can be followed by ShellCheck.
# shellcheck disable=SC2154
set -eu

phase="${1:-}"
case "$phase" in
    phase1 | phase2 | phase3) ;;
    *)
        echo "usage: package-test-steps.sh phase1|phase2|phase3" >&2
        exit 2
        ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
. scripts/package-test-program-lib.sh
. scripts/service-check-lib.sh
. scripts/service-upgrade-lib.sh
. scripts/package-message-lib.sh
. scripts/documented-removal-lib.sh
. scripts/service-run-local.sh
. scripts/system-state-lib.sh
format="${FORMAT:?FORMAT is not set}"
platform="${PLATFORM:?PLATFORM is not set}"
present="${PROGRAMS:?PROGRAMS is not set}"
own="${PACKAGE_TEST_OUT:?PACKAGE_TEST_OUT is not set}"
# Where the host put what it fetched: the published package file of each program is in its folder
# under /pkg, its version is in a file of /baselines named by the program.
baselines="${BASELINES:-/baselines}"
# The name the checks pass on for the system they look at: this one, the only one.
system=system

mkdir -p "$own"
# The host collects the log from the folder, so that nothing depends on a channel to the output of
# the script. Both phases write to the same file.
exec >>"$own/log" 2>&1

# The result is the line of the step that failed, or "ok" when the last step passed. A check ends the
# script with fail, so the line is written however the script ends.
finish() {
    status=$?
    if [ "$status" -ne 0 ]; then
        cat "$own/step-line" >"$own/result" 2>/dev/null || echo "no step was reached" >"$own/result"
    elif [ "$phase" = phase3 ]; then
        echo ok >"$own/result"
    fi
    return "$status"
}
trap finish EXIT

# The programs the service steps are built for; the others wait for their certificate trust setting.
service_step_programs="server"

# use_program for the format of this system: the functions of the format are sourced again, because
# the service manager adapters name the service of the program when they are sourced (only when another
# program was chosen, as in use_program).
use_program_in_system() {
    [ "${chosen_in_system:-}" != "$1" ] || return 0
    use_program "$1"
    # shellcheck source=/dev/null
    . "scripts/service-test-$format.sh"
    # shellcheck source=/dev/null
    . "scripts/package-test-$format.sh"
    chosen_in_system="$1"
}

# The path of the published package file of the system's format: the folder of the program is at
# /pkg/PROGRAM.
published_package_file() {
    published_site_path="$(published_path "$format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
    echo "/pkg/$PROGRAM/published/$(basename "$published_site_path")"
}

# The package files are installed by the system's package manager, so the dependencies come from the
# distribution's mirror, as for a person.
check_installed_files() {
    must "the package manager does not list the package as installed" package_installed "$1"
    must "a file check of the package failed: see the line above" \
        in_system "$1" check_versions check_links check_config_folders check_extras
    definition="$(service_file)"
    must "the service definition $definition is missing" on_system "$1" test -f "$definition"
    must "the service definition does not name the program $bindir/$program" on_system "$1" grep -qF "$bindir/$program" "$definition"
    must "the user $expected_user was not created" on_system "$1" grep -q "^$expected_user:" /etc/passwd
    echo "ok: the package is installed, its files are in place and the user exists"
    check_service_after_package "$1"
}

# Where the published package file is: on a system the host reaches (a container) the host put it
# there, and on one it cannot reach (the FreeBSD machine) the system fetches it itself, with the
# function of its format that does that.
published_file_of_system() {
    if command -v fetch_published_package >/dev/null 2>&1; then
        fetch_published_package "$system" || fail "fetching the published package failed"
    else
        published_package_file
    fi
}

# On a system that fetches the published package itself, the version of the file it got is the baseline:
# what the host read of the site came earlier, and the site can list a newer package by the time the
# system fetches. The version is read from the file once and recorded, and the checks of the steps 1 and
# 2 that need the version of the published package use that one. It runs in the shell of the steps, not in
# a command substitution, because the words it sets are the ones the steps read.
# Usage: record_fetched_version PACKAGE_FILE
record_fetched_version() {
    command -v published_baseline_version >/dev/null 2>&1 || return 0
    # fail ends the system, so the function being part of a condition changes nothing.
    # shellcheck disable=SC2310
    fetched_version="$(published_baseline_version "$system" "$1")" || fail "reading the version of the fetched package failed"
    record_baseline_version "$fetched_version"
}

# Runs the command $2... and shows what it printed, and keeps it in the file $1 too, for the checks of the
# messages a package prints.
keep_output() {
    kept="$1"
    shift
    kept_status=0
    "$@" >"$kept" 2>&1 || kept_status=$?
    cat "$kept"
    return "$kept_status"
}

# The message of the type $1 that the package printed into the file $2 is the one in the manifest of the new
# package file, which is the one that was installed, upgraded to or removed.
check_message_of_new_package() {
    new_file="$(package_file)"
    check_package_message "$1" "$2" "$new_file"
}

# Step 1. The published package is what people have installed. It is the one the record of the
# build names, or the newest on the site; nothing is installed when none is published.
install_baseline() {
    if [ -z "$from" ]; then
        echo "nothing is published for $PROGRAM: there is no baseline, and nothing is installed in this step"
        return 0
    fi
    published_file="$(published_file_of_system)"
    record_fetched_version "$published_file"
    must "installing the published package failed" keep_output "$own/baseline-output" install_published_package "$1" "$published_file"
    check_package_message install "$own/baseline-output" "$published_file"
    must "the package manager does not list the published package as installed" package_installed "$1"
    # The quotes are single on purpose: the variables are those of the shell that sh -c starts.
    # shellcheck disable=SC2016
    must "the installed program does not report the published version $old_tag" \
        on_system "$1" sh -c '"$1" --version | grep -qF "$2"' sh "$program" "$old_tag"
    must "writing the configuration file and the data file failed" in_upgrade_lib "$1" write_markers "$format"
    echo "ok: the published $old_tag is installed, with a configuration file and a data file"
}

# The new package file over what step 1 installed: scripts/upgrade-package-lib.sh is the one place
# that says how (an upgrade, or a reinstall when the version is the same). Usage:
# put_new_package_over SYSTEM INSTALLED_VERSION.
put_new_package_over() {
    new_file="$(package_file)"
    on_system "$1" env DEBIAN_FRONTEND=noninteractive sh -c \
        '. scripts/upgrade-package-lib.sh; upgrade_package "$@"' sh "$format" "$2" "$VERSION" file "$new_file"
}

# Step 2 never goes down. A release published while the run was going is the newest package of the
# site, which a system that fetches its baseline itself gets, and putting the older package under
# test over it would be a downgrade, which no package manager treats as an upgrade. Nothing is
# installed; the run is done again.
refuse_downgrade() {
    # published_is_newer is a test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if published_is_newer "$old_debver" "$debver"; then
        fail "step 2: $PROGRAM: the published $old_tag is newer than the package under test $VERSION; a newer release was published during this run, run it again"
    fi
}

# Step 2, first part. With no baseline the package is installed, and the files that an upgrade
# must keep are written.
install_new_package() {
    if [ -n "$from" ]; then
        refuse_downgrade
        must "putting the new package over the published one failed" keep_output "$own/upgrade-output" put_new_package_over "$1" "$old_tag"
        check_message_of_new_package upgrade "$own/upgrade-output"
        must "the upgrade did not keep the configuration file and the data file" \
            in_upgrade_lib "$1" verify_markers_kept "upgrade"
        return 0
    fi
    must "installing the package failed" keep_output "$own/install-output" install_package "$1"
    check_message_of_new_package install "$own/install-output"
    must "writing the configuration file and the data file failed" in_upgrade_lib "$1" write_markers "$format"
}

# Whether the services of the program are enabled and running, one line each.
service_state() {
    for state_check in service_enabled service_active; do
        if "$state_check" "$1"; then echo "$state_check: yes"; else echo "$state_check: no"; fi
    done
}

# Step 2, second part: the new file over itself. Nothing must change: the files and the checksums
# of /etc as the snapshots list them, what the package promises, the configuration file and the
# data file of step 1, and what the services are doing.
check_reinstall_changes_nothing() {
    take_snapshot "$1" "$own/before-reinstall"
    service_state "$1" >"$own/state-before"
    must "installing the new package file over itself failed" put_new_package_over "$1" "$VERSION"
    take_snapshot "$1" "$own/after-reinstall"
    service_state "$1" >"$own/state-after"
    if ! diff "$own/before-reinstall" "$own/after-reinstall" >"$own/diff"; then
        cat "$own/diff"
        fail "installing the package file over itself changed the system: the lines above differ"
    fi
    must "installing the package file over itself changed the state of a service" \
        cmp -s "$own/state-before" "$own/state-after"
    must "a file check of the package failed after it was installed over itself: see the line above" \
        in_system "$1" check_versions check_links check_config_folders check_extras
    must "installing the package file over itself did not keep the configuration file and the data file" \
        in_upgrade_lib "$1" verify_markers_kept "reinstall"
    echo "ok: installing the package file over itself changed no file, no configuration and no service"
}

# Runs the documented removal as a person would: root, and "yes" for the questions the package
# manager asks. The file says sudo, which root does not have in a container, so sudo is a function
# that runs its arguments. zypper reads its questions from the terminal only and fails on a pipe
# ("Cannot read input"), so the function gives zypper --non-interactive, which answers them with
# their defaults, the same yes. The first failing command ends the run, and tracing (set -x) puts each
# command in the log, so the last one before the failure is the one that failed: a command that
# fails without a message is named that way.
documented_removal() {
    file="$(uninstall_file "$1")" || fail "no uninstall file for this system"
    # fail ends the system, so the functions being part of a condition change nothing.
    # shellcheck disable=SC2310
    held="$(held_packages "$1")" || fail "asking the package manager what it holds failed"
    if [ -z "$held" ]; then
        echo "step 9: $format: nothing installed, the removal command is left out, as the steps say"
    fi
    turned_on="$(programs_turned_on)"
    services_left_out "$file" "$turned_on" | while IFS= read -r line; do
        echo "step 9: $format: \"$line\" is left out, as the steps say"
    done
    # shellcheck disable=SC2310
    text="$(documented_removal_text "$file" "$held" "$turned_on")" || fail "reading $file failed"
    # on_system is one command whose status is the answer, so set -e being off inside it changes nothing.
    # The script is for the shell that sh -c starts, which reads its own variables.
    # shellcheck disable=SC2016,SC2310
    yes | on_system "$1" env DEBIAN_FRONTEND=noninteractive sh -c 'set -ex
        sudo() { if [ "$1" = zypper ]; then shift; zypper --non-interactive "$@"; else "$@"; fi; }
        eval "$1"' sh "$text" ||
        fail "the commands of $file failed"
    echo "ok: the commands of $file ran"
}

# The package manager's plain removal takes the programs and leaves what the administrator and the
# running server wrote, which only a purge or a person deletes.
check_plain_removal() {
    must "the plain removal failed" keep_output "$own/removal-output" remove_package "$1"
    check_message_of_new_package remove "$own/removal-output"
    refuse "the package is still installed after the plain removal" package_installed "$1"
    must "the plain removal left a program of the package behind" in_system "$1" check_programs_removed
    must "a process of ours is still running after the plain removal" no_process_of_ours "$1"
    must "the plain removal took away the configuration file or the data file" \
        in_upgrade_lib "$1" verify_markers_kept "plain removal"
    echo "ok: the programs are gone, the configuration and the data remain"
}

check_nothing_of_ours() {
    refuse "the package is still installed after it was removed" package_installed "$1"
    must "the removal left a program of the package behind" in_system "$1" check_programs_removed
    must "a process of ours is still running" no_process_of_ours "$1"
    echo "ok: nothing of ours is installed or running"
}

# Compares the snapshot of the system with the one of step 0. A core dump may be what differs, so
# the cores are looked for once more, after the snapshot, and every core in the difference is named
# next to it.
check_system_as_it_was() {
    take_snapshot "$1" "$own/after"
    note_new_cores "$1" "$previous_step"
    if ! diff "$own/before" "$own/after" >"$own/diff"; then
        cat "$own/diff"
        name_cores_in_difference "$1" "$own/diff"
        fail "the system is not as it was before the install: the lines above differ"
    fi
    echo "ok: the files and the checksums of /etc are as they were"
}

# Writes the test configuration of the program and finds it where the documentation says. A program
# with no test configuration has none to write.
write_and_check_test_config() {
    [ -f "$defs/test-config.sh" ] || return 0
    must "writing the test configuration failed" in_system "$1" write_test_config
    must "the test configuration is not where the documentation says" in_system "$1" check_test_config
    echo "ok: the test configuration is where the documentation says"
}

# What the test made outside the folders the documented removal deletes, so that the snapshot
# compares only what the package and the documented steps did.
remove_test_data_of_program() {
    [ -f "$defs/test-config.sh" ] || return 0
    must "removing the test data failed" in_system "$1" remove_test_data
}


# The text of step 5, which phase 1 starts and phase 2 finishes.
restart_text="the service is restarted, then the container is, and it works again because it is enabled"

# Enters the step $1 for the owner $2 (a program, or empty for the whole system), with the text $3,
# without printing it: first the core dumps that appeared since the step before it. The line of the
# step goes into a file so that the result names the step the run stopped in, and the step before
# goes into one so that the second phase knows it.
enter_step() {
    note_new_cores "$system" "$previous_step"
    previous_step="step $1${2:+: $2}"
    echo "$previous_step" >"$own/previous-step"
    echo "step $1: ${2:+$2: }$3" >"$own/step-line"
}

begin_step() {
    enter_step "$@"
    cat "$own/step-line"
}

# Runs the command $@ for each program of the run in order, with the program chosen first.
each_program() {
    for step_program in $present; do
        use_program_in_system "$step_program"
        "$@"
    done
}

# Step $1 of a program whose service steps are not built: it says so and nothing is done for it.
begin_waiting_step() {
    begin_step "$1" "$PROGRAM" "service steps wait for the $PROGRAM's certificate trust setting"
}

# Whether the service steps are built for the program $1.
has_service_steps() {
    case " $service_step_programs " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# The programs whose service the steps 3 to 8 turned on, separated by spaces.
programs_turned_on() {
    for step_program in $present; do
        # has_service_steps is one test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        ! has_service_steps "$step_program" || printf '%s ' "$step_program"
    done
}

# Like each_program for a service step, step $1 with the text $2 and the function $3: a program whose
# service steps are not built says so and nothing is done for it.
each_service_program() {
    for step_program in $present; do
        use_program_in_system "$step_program"
        # has_service_steps is one test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        if has_service_steps "$PROGRAM"; then
            begin_step "$1" "$PROGRAM" "$2"
            "$3"
        else
            begin_waiting_step "$1"
        fi
    done
}

step_baseline() {
    begin_step 1 "$PROGRAM" "the published package file is installed"
    install_baseline "$system"
}

step_new_package() {
    begin_step 2 "$PROGRAM" "the new package file is installed over it, and over itself"
    install_new_package "$system"
    check_installed_files "$system"
    check_upgrade_of_running_service "$system"
    check_reinstall_changes_nothing "$system"
}

service_enable_and_configure() {
    check_enable "$system"
    write_and_check_test_config "$system"
}

# Step 1a: the published package's service is turned on and started like steps 3 and 4 do it, and what
# it is is written down; step 2 then puts the new package over a running service. With nothing published
# there is no running service to upgrade.
step_running_baseline() {
    if [ -z "$from" ]; then
        echo "nothing is published for $PROGRAM: the upgrade under a running service is not tested"
        return 0
    fi
    service_enable_and_configure
    service_start_and_check
    note_running_service "$system" "$old_tag"
}

# Steps 3 and 4 turn the service on and start it, unless step 1a did and the upgrade kept it so: then they
# check that it is still so.
step_enable_and_configure() {
    # ran_before_the_package is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if ran_before_the_package; then
        check_still_enabled_and_configured "$system"
    else
        service_enable_and_configure
    fi
}

step_start_and_check() {
    # shellcheck disable=SC2310
    if ran_before_the_package; then
        check_still_running "$system"
    else
        service_start_and_check
    fi
}

service_start_and_check() {
    must "saving the firewall zone files failed" save_firewall_zones "$system" "$own/firewall-zones"
    must "opening the port ${port:-} in the firewall failed" open_firewall "$system"
    check_start "$system"
    check_user "$system"
    check_answers "$system"
}

service_stop_and_check() {
    check_stop "$system"
    must "a process of ours is still running after the stop" no_process_of_ours "$system"
    echo "ok: no process of ours is running after the stop"
}

service_disable_and_check() {
    check_disable "$system"
}

step_plain_removal() {
    begin_step 9 "$PROGRAM" "the package manager's plain removal"
    check_plain_removal "$system"
}

# After the documented removal: what the test made outside the folders it deletes is taken away, the
# firewall is as it was, and nothing of the program is installed or running.
step_after_documented_removal() {
    begin_step 9 "$PROGRAM" "what the test made is taken away, and nothing of the program is left"
    remove_test_data_of_program "$system"
    must "putting the firewall zone files back failed" restore_firewall_zones "$system" "$own/firewall-zones"
    refuse "the port ${port:-} is still open in the firewall after the zone files were put back" port_open_in_firewall "$system"
    check_nothing_of_ours "$system"
}

# Step 5 for each program in the first phase: the restart of the service. A program that has no
# service steps is named in the second phase, where the step ends.
step_restart() {
    for step_program in $present; do
        use_program_in_system "$step_program"
        # shellcheck disable=SC2310
        has_service_steps "$PROGRAM" || continue
        begin_step 5 "$PROGRAM" "$restart_text"
        check_restart "$system"
    done
}

# Step 5 for each program in the second phase, after the host restarted the system: the service
# works again because it is enabled. The step goes on without a new line for the program that began it.
step_after_restart() {
    for step_program in $present; do
        use_program_in_system "$step_program"
        # shellcheck disable=SC2310
        if has_service_steps "$PROGRAM"; then
            enter_step 5 "$PROGRAM" "$restart_text"
            check_after_reboot "$system"
        else
            begin_waiting_step 5
        fi
    done
}

# The steps 0 to 4 and the restart of the service in step 5, the files of the system's folder
# started empty.
phase1() {
    : >"$own/cores-seen"
    : >"$own/cores-noted"
    previous_step="the boot"

    begin_step 0 "" "the vanilla system is written down"
    take_snapshot "$system" "$own/before"

    each_program step_baseline
    each_service_program 1a "the published package's service is enabled, configured and started, to be upgraded while it runs" \
        step_running_baseline
    each_program step_new_package
    each_service_program 3 "the service is enabled, and the test configuration is written through the documented folders" \
        step_enable_and_configure
    each_service_program 4 "the service is started, runs as its own user and does its job" step_start_and_check
    step_restart
}

# The rest of step 5, after the host restarted the system.
phase2() {
    read -r previous_step <"$own/previous-step"

    step_after_restart
}

# The steps 7 to 9.
phase3() {
    read -r previous_step <"$own/previous-step"

    each_service_program 7 "the service is stopped" service_stop_and_check
    each_service_program 8 "the service is disabled" service_disable_and_check

    each_program step_plain_removal
    begin_step 9 "" "the documented removal"
    documented_removal "$system"
    each_program step_after_documented_removal
    begin_step 9 "" "the system is as it was"
    check_system_as_it_was "$system"
}

"$phase"
