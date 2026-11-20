#!/bin/sh
# check-not-run: needs Docker and the packages in dist/PROGRAM (make package-test)
# Tests the new package of the program PROGRAM on every system in packaging/test-systems, all at the
# same time, in ONE boot of the server image per system (its service manager is process 1), the way
# a person installs a package file: no repository and no setup script. Each system runs these steps in
# order, each printed as "step N: ...", and stops at the first wrong result:
#   0. the file list and the checksums of /etc are written down (scripts/lifecycle-snapshot.sh);
#   1. the baseline: the previous published package FILE, fetched once for the whole run from the
#      package site and proven by its signed index (scripts/published-verify.sh), is installed with
#      the system's package manager, and a configuration file and a data file are written. When
#      nothing is published, the step says so and installs nothing;
#   2. the new package FILE is put over it the way scripts/upgrade-package-lib.sh says (an upgrade,
#      or a reinstall when the version is the same); with no baseline it is installed. Every file the
#      package promises is in its place (scripts/package-test-lib.sh), installing enabled and
#      started nothing, and the configuration and data of step 1 are kept. Then the file is put
#      over itself once more: the files, the configuration and the state of the service stay as
#      they were;
#   9. the package manager's plain removal: the programs are gone, the configuration and the data
#      remain. Then the documented removal (the file of steps/ for this system, without the setup
#      script's --remove, which belongs to the setup script test): the package, the data, the
#      configuration, the user and the group; nothing of ours is installed or running, and the
#      snapshot equals the one of step 0, apart from the paths of scripts/lifecycle-excluded.
# The numbers are those of the design of the test; the steps that are not built yet are not run.
# Before every step, the core dumps that appeared since the step before are printed with the program
# that dumped them (scripts/core-files.sh), and beside a difference in step 9 all of them are.
# A failing system does not stop the others, so one run shows every system that is broken. Runs on
# the host (make package-test, CI). Environment: PROGRAM; the version comes from dist/PROGRAM/version,
# which make packages wrote (scripts/package-record.sh), and a VERSION given must be that one;
# PLATFORM (linux/amd64 or linux/arm64) tests that CPU type by emulation, empty means this machine's
# own; ONLY limits the run to one format or image.
#
# What differs between package formats is in scripts/service-test-<format>.sh (install_package,
# service_file, the service functions) and scripts/lifecycle-test-<format>.sh (package_installed,
# uninstall_file); what the service of the program does is in its service-check.sh. None of them
# can be followed by ShellCheck.
# shellcheck disable=SC2154
set -eu

: "${PROGRAM:?PROGRAM is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
. scripts/published-lib.sh
# shellcheck source=/dev/null
. "$defs/service-check.sh"
. scripts/service-check-lib.sh
. scripts/system-state-lib.sh
. scripts/systems-lib.sh
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
package_arches "$platform"
work="$(mktemp -d)"
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

# The documented removal reads as the install page shows it, for both programs. A program that is
# not part of the test is not installed, and a package manager refuses a name it does not know, so
# the names of those packages are left out of the commands. The setup script's own removal is left
# out: it removes the repository this test never set up.
documented_removal_text() {
    {
        echo '/setup\.sh/d'
        for conf in programs/*/program.conf; do
            other="$(sed -n 's/^name=//p' "$conf")"
            [ "$other" != "$name" ] || continue
            echo "s/ $other\$//"
            echo "s/ $other / /"
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
    # fail ends the system, so the function being part of a condition changes nothing.
    # shellcheck disable=SC2310
    text="$(documented_removal_text "$file")" || fail "reading $file failed"
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

# Starts the step $1: first the core dumps that appeared since the step before it. The number goes
# into a file so that the report of the system names the step it stopped in.
step() {
    note_new_cores "$c" "$previous_step"
    previous_step="step ${1%%:*}"
    echo "${1%%:*}" >"$own/step"
    echo "step $1"
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

    step "0: the vanilla system is written down"
    take_snapshot "$c" "$own/before"

    step "1: the published package file is installed"
    install_baseline "$c"

    step "2: the new package file is installed over it, and over itself"
    install_new_package "$c"
    check_installed_files "$c"
    check_reinstall_changes_nothing "$c"

    step "9: the plain removal, the documented removal, and the system is as it was"
    check_plain_removal "$c"
    # The documented removal is for a person whose packages are installed: after the plain removal
    # some package managers refuse its package names (apk does), so the package file is installed
    # once more, as step 2 does with no baseline.
    must "installing the package again failed" install_package "$c"
    documented_removal "$c"
    check_nothing_of_ours "$c"
    check_system_as_it_was "$c"
    note_new_cores "$c" "step 9"
}

# One system, in a container and a folder of its own: number $3 of the list. It runs in a process of
# its own, so the functions of its format, sourced here, are its own too.
# Usage: test_system FORMAT IMAGE NUMBER.
test_system() {
    format="$1"
    container="$prefix-$3"
    own="$work/system-$3"
    mkdir "$own"
    log="$own/log"
    # shellcheck source=/dev/null
    . "scripts/service-test-$format.sh"
    # shellcheck source=/dev/null
    . "scripts/lifecycle-test-$format.sh"
    started=0
    # boot_system is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if boot_system --name "$container" --platform "$platform" \
        -v "$root":/src:ro -v "$root/dist/$PROGRAM":/pkg:ro "$2" 2>"$log"; then
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
        echo "ok   $format $2"
    else
        read -r reached <"$own/step"
        echo "FAIL $format $2 (step $reached)"
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$checked"
}

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

# What step 1 installs and step 2 upgrades: the published version the record of the build names (the
# newest on the site when it names none), as scripts/upgrade-test.sh reads it. $from is empty when
# nothing is published. PUBLISHED_VERSION is what the scripts that run in the systems read.
# upgrade_from_version is a test whose status is the answer, so set -e being off inside it changes nothing.
# shellcheck disable=SC2310
from="$(upgrade_from_version)" ||
    fail "could not read the newest published package of $PROGRAM from $site_url"
published_dir="$root/dist/$PROGRAM/published"
PUBLISHED_VERSION="$VERSION"
if [ -n "$from" ]; then
    # A version that package_release_of_debver refuses ends the script here, with its message.
    use_published_version "$from"
    PUBLISHED_VERSION="$old_tag"
fi
export PUBLISHED_VERSION

# The path of the published package file of the system's format as the systems see it: the dist
# folder of the program is mounted at /pkg.
published_package_file() {
    published_site_path="$(published_path "$format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
    echo "/pkg/published/$(basename "$published_site_path")"
}

# Downloads the published package file of every format that is tested, once for all the systems of
# the format, and proves it by the signed index of the site. A download that fails ends the run
# before any system starts: it is not a failure of the package.
fetch_baselines() {
    [ -n "$from" ] || return 0
    for baseline_format in $(printf '%s\n' "$selected" | awk 'NF { print $1 }' | LC_ALL=C sort -u); do
        baseline_path="$(published_path "$baseline_format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
        # download_published_file is a test whose status is the answer, so set -e being off inside it
        # changes nothing.
        # shellcheck disable=SC2310
        download_published_file "$baseline_path" "$published_dir" ||
            fail "could not download and verify $site_url/$baseline_path"
    done
}
fetch_baselines

run_systems "$work" pull_system test_system <<LIST
$selected
LIST
