#!/bin/sh
# check-not-run: needs Docker, the network and the packages of both programs (make lifecycle-test)
# Tests the whole life of the packages on every system in packaging/test-systems, all at the same
# time, in ONE boot of the server image per system, the way a person would use them: set up our
# repository, install the newest published packages of both programs, upgrade to the new
# packages, remove them, install the new ones fresh, uninstall as the documentation says, and find
# the system as it was.
# Runs on the host after make packages (make lifecycle-test); it needs Docker, curl and python3.
# The steps, in one booted system:
#   1. the file list and the checksums of /etc are written down (scripts/lifecycle-snapshot.sh);
#   2. sh setup.sh, built for the local test site, registers the repository;
#   3. the published packages of the server and the client are installed from the repository, the
#      documented start command enables and starts the services (a release may already have done
#      so), and they are checked;
#   4. the new packages are installed over them with the package manager's upgrade: the running
#      service keeps running, on the new version; the services are checked, restarted and
#      rebooted (the container restarts);
#   5. with both programs installed, one is removed and the other still works;
#   6. the other is removed, and nothing of ours is installed or running;
#   7. the new version is installed fresh over what the removals left: the package is installed
#      and the service is neither enabled nor running, then the documented start command
#      enables and starts it, and the service is checked;
#   8. the documented uninstall (steps/uninstall-<family>.sh, the files the install page and the
#      README show): the packages, the data, the configuration, the user and the group, and
#      sh setup.sh --remove, run as they are written; nothing of ours is installed or running;
#   9. the file list and the checksums of /etc are the same as in step 1, apart from the paths of
#      scripts/lifecycle-excluded.
# Before every step and after the snapshot of step 9, the core dumps that appeared since the step
# before are printed with the program that dumped them (scripts/core-files.sh), so a crash names
# its program and its step; a core in the difference of step 9 is named again next to it.
# The test repository is the newest published packages plus the new ones (scripts/lifecycle-repo.sh,
# make lifecycle-repo), served from this machine like tests/run.sh serves the end to end site. The
# checks are those of the other tests: the service checks (scripts/service-check-lib.sh, the
# service check of each program) and the package checks (scripts/package-test-lib.sh).
# A failing system does not stop the run. Environment: PLATFORM (linux/amd64 or linux/arm64,
# empty means this machine's own); ONLY limits the run to one format or one image.
# What program.conf, the service checks and the format files set is unknown to ShellCheck.
# shellcheck disable=SC2154
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# The programs of the packages repository, as folders of programs/. package-lib.sh sets "programs"
# itself (the program files of one of them), so this list has another name.
packaged="server client"
# package-lib.sh needs a program to be read, and the helpers this script takes from it (boot_system,
# wait_booted, pull_image, system_selected) do not depend on which one it is.
PROGRAM=server
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
. scripts/service-check-lib.sh
. scripts/site-server-lib.sh

platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
for p in $packaged; do
    [ -f "dist/lifecycle/$p/published" ] || fail "dist/lifecycle/$p/published does not exist: run make lifecycle-repo first"
    [ -d "dist/lifecycle/$p/repo" ] || fail "dist/lifecycle/$p/repo does not exist: run make lifecycle-repo first"
done
. scripts/systems-lib.sh
work="$(mktemp -d "$root/dist/lifecycle/run.XXXXXX")"
mkdir "$work/systems"
# Every container of this run carries the process id of this run in its name, so the cleanup finds
# all of them and no other run's.
prefix="splicefs-lifecycle-test-$$"
cleanup() {
    stop_systems
    stop_site_server
    docker ps -aq --filter "name=$prefix-" | xargs docker rm -f >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Runs the command in a shell of its own that knows the program $1 at the version $2: what
# package-lib.sh says about it, what the program's service check says, and the functions of the
# package format. PUBLISHED_VERSION is the version of the published package of the program, which
# decides how the new one is put over it. The shell ends this system's run when the command fails,
# because every check reports with fail. Usage: as_program PROGRAM VERSION COMMAND [ARGUMENT...].
# The subshell is what keeps one program's words from the next one's.
# shellcheck disable=SC2030
as_program() {
    (
        PROGRAM="$1"
        VERSION="$2"
        shift 2
        PACKAGE_DATE="$(sed -n 's/^PACKAGE_DATE=//p' "dist/$PROGRAM/version")"
        PUBLISHED_VERSION="$(sed -n 's/^TAG=//p' "dist/lifecycle/$PROGRAM/published")"
        export PROGRAM VERSION PACKAGE_DATE PUBLISHED_VERSION
        # shellcheck source=/dev/null
        . scripts/package-lib.sh
        # shellcheck source=/dev/null
        . "$defs/service-check.sh"
        # shellcheck source=/dev/null
        . "scripts/service-test-$format.sh"
        # shellcheck source=/dev/null
        . "scripts/lifecycle-test-$format.sh"
        "$@"
    ) || exit 1
}

# The same for the program $1 as it was built (new, the version of the record that make packages
# wrote) or as it was published (the version that scripts/lifecycle-repo.sh wrote down), as
# v1.2.3.
as_new() {
    version="$(sed -n 's/^VERSION=//p' "dist/$1/version")"
    program_name="$1"
    shift
    as_program "$program_name" "$version" "$@"
}
as_published() {
    version="$(sed -n 's/^TAG=//p' "dist/lifecycle/$1/published")"
    program_name="$1"
    shift
    as_program "$program_name" "$version" "$@"
}

# Puts the new package over the published one in the container $1, the way a user upgrades from
# the repository: an upgrade when the new version is higher, a reinstall when it is the same (a
# change to the packaging alone), as scripts/upgrade-package-lib.sh says. It runs inside
# as_program, which sets the words it reads.
# shellcheck disable=SC2031
repo_upgrade() {
    docker exec -e DEBIAN_FRONTEND=noninteractive -w /src "$1" sh -c \
        '. scripts/upgrade-package-lib.sh; upgrade_package "$@"' sh "$format" "$PUBLISHED_VERSION" "$VERSION" repo "$name"
}

# Runs the package checks of scripts/package-test-lib.sh, which look at the system they run in,
# inside the container $1: the checks named by the other arguments, for the program and version
# of the caller. The repository is mounted at /src, where those scripts read their definitions.
in_system() {
    container_name="$1"
    shift
    docker exec -e PROGRAM -e VERSION -e PACKAGE_DATE -w /src "$container_name" sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh; for check in "$@"; do "$check"; done' sh "$@"
}

# What a fresh install does to the service: the package is installed and the service is idle.
# Starting it is the administrator's decision, so the documented command does it, and the
# service then runs as its own user and does its job.
check_service_after_install() {
    must "the package is not installed after the install" package_installed "$1"
    check_idle_after_install "$1"
    check_documented_start "$1"
    check_user "$1"
    check_answers "$1"
}

# The published package is whatever was published: a package made before the packages stopped
# starting the service on install starts it, a later one leaves it idle. Which it is is not
# this test's to judge, so only the state the next steps need is made and checked: installed, and
# enabled and running by the documented command, which changes nothing when it is so already.
check_service_after_published_install() {
    must "the package is not installed after the install" package_installed "$1"
    check_documented_start "$1"
    check_user "$1"
    check_answers "$1"
}

# The service of a program that was upgraded runs as before the upgrade, which
# check_upgrade_keeps_running has proved, and it restarts and comes back after a reboot.
check_service_after_upgrade() {
    check_user "$1"
    check_restart "$1"
    check_reboot "$1"
}

# Nothing of our programs runs: no process has one of their files as its program, also not one
# that was started from a file that is gone now. /proc is what every system has.
no_process_of_ours() {
    docker exec "$1" sh -c '
        for dir in /proc/[0-9]*; do
            case "$(readlink "$dir/exe" 2>/dev/null)" in
                */splicefs*) exit 1 ;;
                *) ;;
            esac
        done'
}

# Both programs are removed, which means: not installed according to the package manager, no
# program file left in /usr/bin, nothing running.
check_nothing_of_ours() {
    for p in $packaged; do
        as_new "$p" refuse "$p is still installed after it was removed" package_installed "$1"
        as_new "$p" in_system "$1" check_programs_removed
    done
    must "a process of ours is still running" no_process_of_ours "$1"
    echo "ok: nothing of ours is installed or running"
}

# Runs the uninstall file of this system's package family exactly as it is written, as a person
# would: root, the setup script from step 1 in the home folder, and "yes" for the questions the
# package manager asks. The file says sudo, which root does not have in a container, so sudo is
# a function that runs its arguments. zypper reads its questions from the terminal only and fails
# on a pipe ("Cannot read input"), so the function gives zypper --non-interactive, which answers
# them with their defaults, the same yes. The first failing command ends the run.
documented_uninstall() {
    file="$(uninstall_file "$1")" || fail "no uninstall file for this system"
    must "copying the setup script to the home folder failed" docker exec "$1" sh -c 'cp /site/setup.sh ~/splicefs-setup.sh'
    yes | docker exec -i -e DEBIAN_FRONTEND=noninteractive "$1" sh -c 'set -e
        sudo() { if [ "$1" = zypper ]; then shift; zypper --non-interactive "$@"; else "$@"; fi; }
        . "/src/$1"' sh "$file" ||
        fail "the commands of $file failed"
    echo "ok: the commands of $file ran"
    # The copy stands in for the download of the person, who deletes it themselves.
    must "removing the copy of the setup script failed" docker exec "$1" sh -c 'rm ~/splicefs-setup.sh'
}

# Writes the snapshot of the system into the file $2 on the host.
take_snapshot() {
    docker exec "$1" sh /src/scripts/lifecycle-snapshot.sh >"$2" || fail "the snapshot of the system failed"
}

# Prints the core dumps that appeared in the system $1 since the last call, with what ran before
# them ($2), so that a crash in any step names its program and its step (scripts/core-files.sh).
# They are also kept in cores-noted, for the comparison of step 9 to name them again next to it.
note_new_cores() {
    docker exec "$1" sh /src/scripts/core-files.sh >"$own/cores-now" || fail "looking for core dumps failed"
    grep -vxFf "$own/cores-seen" "$own/cores-now" | sed "s/^/core dump after $2: /" | tee -a "$own/cores-noted" || true
    mv "$own/cores-now" "$own/cores-seen"
}

# Prints, for every path of a core in the difference $2 of step 9, the core dump as a step noted
# it, or else what the file in the system $1 is now: a core can be incomplete when it is looked at,
# because the host's handler writes it while the system runs on.
name_cores_in_difference() {
    sed -n 's|^[<>] \(.*/core[^/]*\)$|\1|p' "$2" | while IFS= read -r path; do
        grep -F ": $path pid " "$own/cores-noted" ||
            docker exec "$1" sh /src/scripts/core-files.sh "$path" | sed "s/^/core dump no step could read: /" ||
            fail "looking at $path failed"
    done
}

# Starts the step $1 of the system $c: first the core dumps of the step before it.
step() {
    note_new_cores "$c" "$previous_step"
    previous_step="step $1"
    echo "step $1"
}

# One system, in the order of the steps in the header, with its files in the folder $own. The
# caller runs this in a subshell so that fail, which every check calls, ends only this system.
run_lifecycle() {
    c="$1"
    # wait_booted is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_booted "$format" "$c" || {
        echo "--- last 30 lines of the container output"
        docker logs --tail 30 "$c" 2>&1 || true
        fail "the service manager did not finish booting"
    }
    # The administrator opens the port of the server before anything is installed, so it is part
    # of the system as it was before the test.
    as_new server must "opening the port in the firewall failed" open_firewall "$c"
    : >"$own/cores-seen"
    : >"$own/cores-noted"
    previous_step="the boot"

    step "1: the vanilla system is written down"
    take_snapshot "$c" "$own/before"

    step "2: sh setup.sh"
    must "setup.sh failed" docker exec "$c" sh /site/setup.sh
    as_new server must "refreshing the package index failed" repo_refresh "$c"

    step "3: the published package is installed from the repository"
    for p in $packaged; do
        as_published "$p" must "installing the published $p failed" repo_install "$c"
        as_published "$p" in_system "$c" check_service_version
        as_published "$p" check_service_after_published_install "$c"
    done

    step "4: the upgrade to the new packages"
    for p in $packaged; do
        as_new "$p" check_upgrade_keeps_running "$c" repo_upgrade
        as_new "$p" in_system "$c" check_versions
        as_new "$p" check_service_after_upgrade "$c"
    done

    step "5: one program is removed, the other still works"
    as_new server check_removal "$c"
    as_new client must "the client stopped working when the server was removed" \
        wait_for 10 active_and_answering "$c"

    step "6: the other program is removed"
    as_new client check_removal "$c"
    check_nothing_of_ours "$c"

    step "7: the new version is installed fresh"
    for p in $packaged; do
        as_new "$p" must "installing $p failed" repo_install "$c"
        as_new "$p" in_system "$c" check_versions check_links check_config_folders check_extras
        as_new "$p" check_service_after_install "$c"
    done

    step "8: the documented uninstall"
    as_new server documented_uninstall "$c"
    for p in $packaged; do
        as_new "$p" check_stopped_after_removal "$c"
    done
    check_nothing_of_ours "$c"

    step "9: the system is as it was"
    take_snapshot "$c" "$own/after"
    note_new_cores "$c" "$previous_step"
    if ! diff "$own/before" "$own/after" >"$own/diff"; then
        cat "$own/diff"
        name_cores_in_difference "$c" "$own/diff"
        fail "the system is not as it was before the setup: the lines above differ"
    fi
    echo "ok: the files and the checksums of /etc are as they were"
}

systems="$(cat packaging/test-systems)"

# The site is built once the port is known: its address is part of the setup script and of its
# checksum. Both repositories are signed with one set of keys, so one setup script trusts both.
# Every system reads the same site, and none writes to it.
site="$work/site"
start_site_server "$site" "$work"
KEYS_DIR="$root/dist/keys" BASE_URL="http://host.docker.internal:$site_port" SITE_DIR="$site" \
    sh scripts/build-site.sh >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; exit 1; }
for p in $packaged; do cp -R "dist/lifecycle/$p/repo" "$site/$p"; done

# One system, in a container and a folder of its own: number $3 of the list.
# Usage: test_system FORMAT IMAGE NUMBER.
test_system() {
    format="$1"
    container="$prefix-$3"
    own="$work/system-$3"
    mkdir "$own"
    log="$own/log"
    # The options of both programs: the server publishes its port. run_options prints whole
    # options and nothing else, so it is left unquoted on purpose.
    options=""
    for p in $packaged; do
        options="$options $(as_new "$p" run_options)"
    done
    started=0
    # boot_system is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2086,SC2310
    if boot_system --name "$container" --platform "$platform" --add-host=host.docker.internal:host-gateway \
        -v "$site":/site:ro -v "$root":/src:ro $options "$2" 2>"$log"; then
        started=1
    fi

    # Errexit is switched off here on purpose: every command of run_lifecycle is guarded with
    # fail, and a failing check must end only this system, not the whole run.
    checked=1
    if [ "$started" -eq 1 ]; then
        set +e
        (run_lifecycle "$container") >>"$log" 2>&1
        checked=$?
        set -e
    fi
    if [ "$checked" -eq 0 ]; then
        echo "ok   $format $2"
    else
        echo "FAIL $format $2"
        tail -n 70 "$log" | sed 's/^/     /'
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$checked"
}

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

run_systems "$work/systems" pull_system test_system <<LIST
$selected
LIST
