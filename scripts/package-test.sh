#!/bin/sh
# check-not-run: needs Docker and the packages in dist/server and dist/client (make package-test)
# Tests the new packages of the programs server and client on every system in packaging/test-systems,
# all at the same time, in ONE boot of the server image per system (its service manager is process 1),
# the way a person installs a package file: no repository and no setup script. Every program whose
# folder dist/PROGRAM holds packages is tested in that one boot, the server first; the folder of a
# program is mounted at /pkg/PROGRAM, and a program whose folder is missing or empty is left out
# ("PROGRAM: no packages, left out"). Each system runs these steps in order, each printed as
# "step N: PROGRAM: ..." for every program in turn, and stops at the first wrong result:
#   0. the file list and the checksums of /etc are written down once (scripts/lifecycle-snapshot.sh);
#   1. the baseline: the previous published package FILE of the program, fetched once for the whole
#      run from the package site and proven by its signed index (scripts/published-verify.sh), is
#      installed with the system's package manager, and a configuration file and a data file are
#      written. The signing key of the project, fetched once from the site and proven to be the
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
#   5. the service is restarted, then the container is, and the service is active and does its job
#      again, because it is enabled;
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
# Before every step, the core dumps that appeared since the step before are printed with the program
# that dumped them (scripts/core-files.sh), and beside a difference in step 9 all of them are.
# A failing system does not stop the others, so one run shows every system that is broken. Runs on
# the host (make package-test, CI). Environment: the version of each program comes from
# dist/PROGRAM/version, which make packages wrote (scripts/package-record.sh), and a VERSION given
# must be that one for every program in the run; PLATFORM (linux/amd64 or linux/arm64) tests that CPU
# type by emulation, empty means this machine's own; ONLY limits the run to one format or image.
#
# What differs between package formats is in scripts/service-test-<format>.sh (install_package,
# service_file, the service functions) and scripts/lifecycle-test-<format>.sh (package_installed,
# uninstall_file); what the service of the program does is in its service-check.sh. None of them
# can be followed by ShellCheck.
# shellcheck disable=SC2154
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
. scripts/service-check-lib.sh
. scripts/system-state-lib.sh
. scripts/systems-lib.sh
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
work="$(mktemp -d)"
# The public signing keys of the package site, which step 1 gives the package managers of the systems:
# mounted at /keys, filled by fetch_baselines.
keys_dir="$work/keys"
mkdir "$keys_dir"
# Every container of this run carries the process id of this run in its name, so the cleanup finds
# all of them and no other run's.
prefix="splicefs-package-test-$$"
cleanup() {
    stop_systems
    docker ps -aq --filter "name=$prefix-" | xargs docker rm -f >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# A VERSION given by hand must be the recorded one of every program in the run.
given_version="${VERSION:-}"

# The programs of a run, in the order they are tested and each step is run for them. The service
# steps (3, 4, 5, 7 and 8) are built for the programs in the second list; the client's wait for its
# certificate trust setting.
all_programs="server client"
service_step_programs="server"

# Whether dist/$1 holds packages: a missing or empty folder is a program that is not tested.
has_packages() {
    for entry in "dist/$1"/* "dist/$1"/.[!.]*; do
        [ -e "$entry" ] && return 0
    done
    return 1
}

present=""
for candidate in $all_programs; do
    # has_packages is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if has_packages "$candidate"; then
        present="$present${present:+ }$candidate"
    else
        echo "$candidate: no packages, left out"
    fi
done
if [ -z "$present" ]; then
    echo "FAIL: no packages in dist/server or dist/client: run make packages first" >&2
    exit 1
fi

# The newest published package of the program, which step 1 installs and step 2 upgrades: the version
# the record of the build names (the newest on the site when it names none), as scripts/upgrade-test.sh
# reads it. The site is asked once for each program of the run, by the first call, before any system
# starts, and the answer is kept in a file for the systems. Sets $from, empty when nothing is
# published, and PUBLISHED_VERSION, which the scripts that run in the systems read.
set_baseline() {
    baseline_file="$work/baseline-$PROGRAM"
    if [ ! -f "$baseline_file" ]; then
        # upgrade_from_version is a test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        upgrade_from_version >"$baseline_file.new" ||
            fail "could not read the newest published package of $PROGRAM from $site_url"
        mv "$baseline_file.new" "$baseline_file"
    fi
    from="$(cat "$baseline_file")"
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
    VERSION="$given_version"
    # The status ends the run here also in a system, where errexit is off; the function says why.
    # shellcheck disable=SC2310
    use_recorded_version || exit 1
    . scripts/package-lib.sh
    . scripts/published-lib.sh
    unset port health_path
    # shellcheck source=/dev/null
    . "$defs/service-check.sh"
    package_arches "$platform"
    published_dir="$root/dist/$PROGRAM/published"
    set_baseline
}

# use_program for a program in a system of the format $format: the functions of the format are
# sourced again, because the service manager adapters name the service of the program when they are
# sourced.
use_program_in_system() {
    use_program "$1"
    # shellcheck source=/dev/null
    . "scripts/service-test-$format.sh"
    # shellcheck source=/dev/null
    . "scripts/lifecycle-test-$format.sh"
}

# The package files are installed by the system's package manager. It runs in the booted system,
# so the dependencies come from the distribution's mirror, as for a person.
check_installed_files() {
    must "the package manager does not list the package as installed" package_installed "$1"
    must "a file check of the package failed: see the line above" \
        in_system "$1" check_versions check_links check_config_folders check_extras
    definition="$(service_file)"
    must "the service definition $definition is missing" docker exec "$1" test -f "$definition"
    refuse "the service definition points at /usr/local/bin" docker exec "$1" grep -q /usr/local/bin "$definition"
    must "the user $expected_user was not created" docker exec "$1" grep -q "^$expected_user:" /etc/passwd
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
    # The quotes are single on purpose: the variables are those of the shell inside the system.
    # shellcheck disable=SC2016
    must "the installed program does not report the published version $old_tag" \
        docker exec "$1" sh -c '"$1" --version | grep -qF "$2"' sh "$program" "$old_tag"
    must "writing the configuration file and the data file failed" in_upgrade_lib "$1" write_markers "$format"
    echo "ok: the published $old_tag is installed, with a configuration file and a data file"
}

# The new package file over what step 1 installed: scripts/upgrade-package-lib.sh is the one place
# that says how (an upgrade, or a reinstall when the version is the same). It runs in the booted
# system. Usage: put_new_package_over CONTAINER INSTALLED_VERSION.
put_new_package_over() {
    new_file="$(package_file)"
    docker exec -e DEBIAN_FRONTEND=noninteractive -w /src "$1" sh -c \
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
    yes | docker exec -i -e DEBIAN_FRONTEND=noninteractive "$1" sh -c 'set -e
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
# the cores in the system are named beside the difference.
check_system_as_it_was() {
    take_snapshot "$1" "$own/after"
    if ! diff "$own/before" "$own/after" >"$own/diff"; then
        cat "$own/diff"
        docker exec "$1" sh /src/scripts/core-files.sh | sed 's/^/core dump in the system: /' || true
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

# Starts the step $1 for the owner $2 (a program, or empty for the whole system), with the text $3:
# first the core dumps that appeared since the step before it. The number goes into a file so that
# the report of the system names the step it stopped in.
begin_step() {
    note_new_cores "$c" "$previous_step"
    previous_step="step $1${2:+: $2}"
    echo "$1" >"$own/step"
    echo "step $1: ${2:+$2: }$3"
}

# Runs the command $@ for each program of the run in order, with the program chosen first.
each_program() {
    for step_program in $present; do
        use_program_in_system "$step_program"
        "$@"
    done
}

# Like each_program for a service step, step $1 with the text $2 and the function $3: a program whose
# service steps are not built says so and nothing is done for it.
each_service_program() {
    for step_program in $present; do
        use_program_in_system "$step_program"
        case " $service_step_programs " in
            *" $PROGRAM "*)
                begin_step "$1" "$PROGRAM" "$2"
                "$3"
                ;;
            *) begin_step "$1" "$PROGRAM" "service steps wait for the $PROGRAM's certificate trust setting" ;;
        esac
    done
}

step_baseline() {
    begin_step 1 "$PROGRAM" "the published package file is installed"
    install_baseline "$c"
}

step_new_package() {
    begin_step 2 "$PROGRAM" "the new package file is installed over it, and over itself"
    install_new_package "$c"
    check_installed_files "$c"
    check_reinstall_changes_nothing "$c"
}

service_enable_and_configure() {
    check_enable "$c"
    write_and_check_test_config "$c"
}

service_start_and_check() {
    must "saving the firewall zone files failed" save_firewall_zones "$c" "$own/firewall-zones"
    must "opening the port ${port:-} in the firewall failed" open_firewall "$c"
    check_start "$c"
    check_user "$c"
    check_answers "$c"
}

service_restart_and_reboot() {
    check_restart "$c"
    check_reboot "$c"
}

service_stop_and_check() {
    check_stop "$c"
    must "a process of ours is still running after the stop" no_process_of_ours "$c"
    echo "ok: no process of ours is running after the stop"
}

service_disable_and_check() {
    check_disable "$c"
}

step_plain_removal() {
    begin_step 9 "$PROGRAM" "the package manager's plain removal"
    check_plain_removal "$c"
}

# After the documented removal: what the test made outside the folders it deletes is taken away, the
# firewall is as it was, and nothing of the program is installed or running.
step_after_documented_removal() {
    begin_step 9 "$PROGRAM" "what the test made is taken away, and nothing of the program is left"
    remove_test_data_of_program "$c"
    must "putting the firewall zone files back failed" restore_firewall_zones "$c" "$own/firewall-zones"
    refuse "the port ${port:-} is still open in the firewall after the zone files were put back" port_open_in_firewall "$c"
    check_nothing_of_ours "$c"
}

# One system, in the order of the steps in the header, with its files in the folder $own. The
# caller runs this in a subshell so that fail, which every check calls, ends only this system.
run_steps() {
    c="$1"
    # wait_booted is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_booted "$format" "$c" || {
        echo "--- last 30 lines of the container output"
        docker logs --tail 30 "$c" 2>&1 || true
        fail "the service manager did not finish booting"
    }
    : >"$own/cores-seen"
    previous_step="the boot"

    begin_step 0 "" "the vanilla system is written down"
    take_snapshot "$c" "$own/before"

    each_program step_baseline
    each_program step_new_package
    each_service_program 3 "the service is enabled, and the test configuration is written through the documented folders" \
        service_enable_and_configure
    each_service_program 4 "the service is started, runs as its own user and does its job" service_start_and_check
    each_service_program 5 "the service is restarted, then the container is, and it works again because it is enabled" \
        service_restart_and_reboot
    each_service_program 7 "the service is stopped" service_stop_and_check
    each_service_program 8 "the service is disabled" service_disable_and_check

    each_program step_plain_removal
    begin_step 9 "" "the documented removal"
    documented_removal "$c"
    each_program step_after_documented_removal
    begin_step 9 "" "the system is as it was"
    check_system_as_it_was "$c"
    note_new_cores "$c" "step 9"
}

# One system, in a container and a folder of its own: number $3 of the list. It runs in a process of
# its own, so the functions of its format, sourced here, are its own too.
# Usage: test_system FORMAT IMAGE NUMBER.
test_system() {
    format="$1"
    image="$2"
    container="$prefix-$3"
    own="$work/system-$3"
    mkdir "$own"
    log="$own/log"
    started=0
    # The folder of each program is mounted at /pkg/PROGRAM. What the service check of a program says
    # the container needs to be reached is given to docker run: the server publishes its port, so
    # that the health endpoint is asked from outside.
    set -- --name "$container" --platform "$platform" -v "$root":/src:ro -v "$keys_dir":/keys:ro
    options=""
    for system_program in $present; do
        use_program "$system_program"
        set -- "$@" -v "$root/dist/$system_program":"/pkg/$system_program":ro
        options="$options $(run_options)"
    done
    # run_options prints whole options and nothing else, so $options is left unquoted on purpose.
    # boot_system is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2086,SC2310
    if boot_system "$@" $options "$image" 2>"$log"; then
        started=1
    fi

    # Errexit is switched off here on purpose: every command of run_steps is guarded with
    # fail, and a failing check must end only this system, not the whole run.
    checked=1
    echo 0 >"$own/step"
    if [ "$started" -eq 1 ]; then
        set +e
        (run_steps "$container") >>"$log" 2>&1
        checked=$?
        set -e
    fi
    cat "$log"
    if [ "$checked" -eq 0 ]; then
        echo "ok   $format $image"
    else
        read -r reached <"$own/step"
        echo "FAIL $format $image (step $reached)"
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$checked"
}

# Choosing the first program is what sources scripts/package-lib.sh, which has the helpers every
# step below uses (fail, must, system_selected, boot_system).
use_program "${present%% *}"

systems="$(cat packaging/test-systems)"
selected=""
# A here-document keeps the list in this shell; a pipe would run the loop in a subshell.
while read -r format image; do
    # Blank lines and comments are skipped; every other line is a system to test.
    case "$format" in "" | "#"*) continue ;; *) ;; esac
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
    for needed in "scripts/service-test-$format.sh" "scripts/lifecycle-test-$format.sh"; do
        [ -f "$needed" ] || fail "$needed does not exist"
    done
    selected="$selected$format $image
"
done <<LIST
$systems
LIST

# The path of the published package file of the system's format as the systems see it: the dist
# folder of the program is mounted at /pkg/PROGRAM.
published_package_file() {
    published_site_path="$(published_path "$format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
    echo "/pkg/$PROGRAM/published/$(basename "$published_site_path")"
}

# Downloads the signing keys of the site once, and the published package file of every format that is
# tested, for each program of the run, once for all the systems of the format. The keys are proven to
# be the repository's keys, a package file by the signed index of the site. A download that fails ends
# the run before any system starts: it is not a failure of the package. Choosing the program is what
# reads its baseline from the site, for the systems too.
fetch_baselines() {
    for baseline_program in $present; do
        use_program "$baseline_program"
        [ -n "$from" ] || continue
        # The keys are needed once, by the first program that has a published package.
        # download_published_keys is a test whose status is the answer, so set -e being off inside it changes nothing.
        # shellcheck disable=SC2310
        [ -f "$keys_dir/splicefs.asc" ] || download_published_keys "$keys_dir" ||
            fail "could not download and verify the signing keys at $site_root/keys"
        for baseline_format in $(printf '%s\n' "$selected" | awk 'NF { print $1 }' | LC_ALL=C sort -u); do
            baseline_path="$(published_path "$baseline_format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
            # download_published_file is a test whose status is the answer, so set -e being off inside it
            # changes nothing.
            # shellcheck disable=SC2310
            download_published_file "$baseline_path" "$published_dir" ||
                fail "could not download and verify $site_url/$baseline_path"
        done
    done
}
fetch_baselines

run_systems "$work" pull_system test_system <<LIST
$selected
LIST
