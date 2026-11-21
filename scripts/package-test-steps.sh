#!/bin/sh
# check-not-run: runs inside a system the packages are installed in (scripts/package-test.sh starts it in a container)
# The steps of the package test, run INSIDE the system under test, as root, with only what that
# system has: its own /bin/sh (dash, bash or busybox ash), its package manager and its service
# manager. The host (scripts/package-test.sh) boots the system, runs this script as phase 1, restarts
# the system, runs it as phase 2 and collects the output folder; it does nothing else to the
# system, so every step is the same wherever the system runs. Usage:
#   sh scripts/package-test-steps.sh phase1|phase2
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
#      says so and installs nothing;
#   2. the new package FILE is put over it the way scripts/upgrade-package-lib.sh says (an upgrade,
#      or a reinstall when the version is the same); with no baseline it is installed. Every file the
#      package promises is in its place (scripts/package-test-lib.sh), installing enabled and
#      started nothing, and the configuration and data of step 1 are kept. Then the file is put
#      over itself once more: the files, the configuration and the state of the service stay as
#      they were;
#   3. the service is enabled with the documented command, and the program's test configuration
#      (programs/PROGRAM/test-config.sh: the server serves one share with one user) is written
#      through the documented folders and found where the documentation says;
#   4. on a system that runs firewalld, the zone files it changes for an open port (public.xml and
#      public.xml.old) are saved, each as a copy or a note that it is missing, and the port of the
#      service is opened; the service is started with the documented command, runs as its own user
#      and does its job (the service check of the program: the server answers its health endpoint
#      from outside);
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
#      out, as the steps tell a person to do): the data, the configuration, the user and the group.
#      Then, program by program, the data the test made is removed, the saved zone files are put back
#      byte for byte (a file that did not exist is deleted) and the port is closed in the firewall,
#      and nothing of ours is installed or running; and the snapshot equals the one of step 0, apart
#      from the paths of scripts/lifecycle-excluded.
# The numbers are those of the design of the test. The steps 3, 4, 5, 7 and 8 are built for the
# server only: for the client each prints "service steps wait for the client's certificate trust
# setting" and does nothing. Step 6, the modes of the client, is not built yet.
# Phase 1 is the steps 0 to 4 and the restart of the service in step 5; phase 2, after the host
# restarted the system, is the rest of step 5 and the steps 7 to 9.
# Before every step and after the snapshot of step 9, the core dumps that appeared since the step
# before are printed with the program that dumped them (scripts/core-files.sh), so a crash names its
# program and its step; a core in the difference of step 9 is named again next to it.
# The log of both phases and the result ("ok", or the line of the step that failed) are written into
# the folder PACKAGE_TEST_OUT, which the host collects; so are the files the phases pass on to each
# other. The folder is on the system's own disk, which a restart keeps, and its path is left out of
# the snapshots (scripts/lifecycle-excluded). Environment: FORMAT (deb, rpm or apk), PLATFORM
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
    phase1 | phase2) ;;
    *)
        echo "usage: package-test-steps.sh phase1|phase2" >&2
        exit 2
        ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
. scripts/service-check-lib.sh
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
    elif [ "$phase" = phase2 ]; then
        echo ok >"$own/result"
    fi
    return "$status"
}
trap finish EXIT

# The programs the service steps are built for; the others wait for their certificate trust setting.
service_step_programs="server"

# The version of each program comes from dist/PROGRAM/version, which make packages wrote (it is in
# the repository at /src). The published package of the program, which step 1 installs and step 2
# upgrades, is the one the host named in its baseline file; empty when nothing is published. Sets
# $from, and PUBLISHED_VERSION, which the scripts that run in the steps read.
set_baseline() {
    from="$(cat "$baselines/$PROGRAM")"
    PUBLISHED_VERSION="$VERSION"
    if [ -n "$from" ]; then
        # A version that package_release_of_debver refuses ends the script here, with its message.
        use_published_version "$from"
        PUBLISHED_VERSION="$old_tag"
    fi
    export PUBLISHED_VERSION
}

# Chooses the program $1: the one place that sets what differs between the programs of a run, so
# that every step reads it from here. They are what the record of its build says (its version), what
# scripts/package-lib.sh makes of that (the package names and versions, the programs and folders to
# check), what its service check says (programs/PROGRAM/service-check.sh), where its published
# package is, and the published baseline. What the service check of the program before it set and
# the next does not is unset first, so that it is not taken for the next program's.
use_program() {
    PROGRAM="$1"
    export PROGRAM
    VERSION=""
    # The status ends the run here, where errexit is off in a check; the function says why.
    # shellcheck disable=SC2310
    use_recorded_version || exit 1
    . scripts/package-lib.sh
    . scripts/published-lib.sh
    unset port health_path
    # shellcheck source=/dev/null
    . "$defs/service-check.sh"
    package_arches "$platform"
    set_baseline
}

# use_program for the format of this system: the functions of the format are sourced again, because
# the service manager adapters name the service of the program when they are sourced.
use_program_in_system() {
    use_program "$1"
    # shellcheck source=/dev/null
    . "scripts/service-test-$format.sh"
    # shellcheck source=/dev/null
    . "scripts/package-test-$format.sh"
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
    refuse "the service definition points at /usr/local/bin" on_system "$1" grep -q /usr/local/bin "$definition"
    must "the user $expected_user was not created" on_system "$1" grep -q "^$expected_user:" /etc/passwd
    echo "ok: the package is installed, its files are in place and the user exists"
    check_idle_after_install "$1"
}

# Step 1. The published package is what people have installed. It is the one the record of the
# build names, or the newest on the site; nothing is installed when none is published.
install_baseline() {
    if [ -z "$from" ]; then
        echo "nothing is published for $PROGRAM: there is no baseline, and nothing is installed in this step"
        return 0
    fi
    published_file="$(published_package_file)"
    must "installing the published package failed" install_published_package "$1" "$published_file"
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

# Step 2, first part. With no baseline the package is installed, and the files that an upgrade
# must keep are written.
install_new_package() {
    if [ -n "$from" ]; then
        must "putting the new package over the published one failed" put_new_package_over "$1" "$old_tag"
        must "the upgrade did not keep the configuration file and the data file" \
            in_upgrade_lib "$1" verify_markers_kept "upgrade"
        return 0
    fi
    must "installing the package failed" install_package "$1"
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
# The documented removal reads as the install page shows it, for both programs, and says "Leave out
# the one you did not install": its removal command names the packages in $2 (what the package
# manager still holds, separated by spaces) and the others are left out of it. With none named the
# command is left out whole: a package manager refuses a name it does not hold, and a command with
# no name does nothing. The setup script's own removal is left out too: it removes the repository
# this test never set up.
documented_removal_text() {
    {
        echo '/setup\.sh/d'
        for conf in programs/*/program.conf; do
            other="$(sed -n 's/^name=//p' "$conf")"
            case " $2 " in
                *" $other "*) ;;
                *)
                    if [ -n "$2" ]; then
                        echo "s/ $other\$//"
                        echo "s/ $other / /"
                    else
                        echo "/ $other\$/d"
                        echo "/ $other /d"
                    fi
                    ;;
            esac
        done
    } >"$own/removal.sed"
    sed -f "$own/removal.sed" "$1"
}

# Runs the documented removal as a person would: root, and "yes" for the questions the package
# manager asks. The file says sudo, which root does not have in a container, so sudo is a function
# that runs its arguments. zypper reads its questions from the terminal only and fails on a pipe
# ("Cannot read input"), so the function gives zypper --non-interactive, which answers them with
# their defaults, the same yes. The first failing command ends the run.
documented_removal() {
    file="$(uninstall_file "$1")" || fail "no uninstall file for this system"
    # fail ends the system, so the functions being part of a condition change nothing.
    # shellcheck disable=SC2310
    held="$(held_packages "$1")" || fail "asking the package manager what it holds failed"
    if [ -z "$held" ]; then
        echo "step 9: $format: nothing installed, the removal command is left out, as the steps say"
    fi
    # shellcheck disable=SC2310
    text="$(documented_removal_text "$file" "$held")" || fail "reading $file failed"
    # on_system is one command whose status is the answer, so set -e being off inside it changes nothing.
    # The script is for the shell that sh -c starts, which reads its own variables.
    # shellcheck disable=SC2016,SC2310
    yes | on_system "$1" env DEBIAN_FRONTEND=noninteractive sh -c 'set -e
        sudo() { if [ "$1" = zypper ]; then shift; zypper --non-interactive "$@"; else "$@"; fi; }
        eval "$1"' sh "$text" ||
        fail "the commands of $file failed"
    echo "ok: the commands of $file ran"
}

# The package manager's plain removal takes the programs and leaves what the administrator and the
# running server wrote, which only a purge or a person deletes.
check_plain_removal() {
    must "the plain removal failed" remove_package "$1"
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
    check_reinstall_changes_nothing "$system"
}

service_enable_and_configure() {
    check_enable "$system"
    write_and_check_test_config "$system"
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
    each_program step_new_package
    each_service_program 3 "the service is enabled, and the test configuration is written through the documented folders" \
        service_enable_and_configure
    each_service_program 4 "the service is started, runs as its own user and does its job" service_start_and_check
    step_restart
}

# The rest of step 5 and the steps 7 to 9, after the host restarted the system.
phase2() {
    read -r previous_step <"$own/previous-step"

    step_after_restart
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
