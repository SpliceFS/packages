#!/bin/sh
# Tests the whole life of the packages on every system in packaging/test-systems, in ONE boot of
# the server image per system, the way a person would use them: set up our repository, install
# the published release of both programs, upgrade to the new packages, remove them, install the
# new ones fresh, remove them, take our repository away again, and find the system as it was.
# Runs on the host after make packages (make lifecycle-test); it needs Docker, curl, python3 and
# openssl. The steps, in one booted system:
#   1. the file list and the checksums of /etc are written down (scripts/lifecycle-snapshot.sh);
#   2. sh setup.sh, built for the local test site, registers the repository;
#   3. the published release of the server and the client is installed from the repository and
#      the services are checked (check_service_after_install is what an install does today);
#   4. the new packages are installed over them with the package manager's upgrade; the services
#      are checked, restarted and rebooted (the container restarts);
#   5. with both programs installed, one is removed and the other still works;
#   6. the other is removed, and nothing of ours is installed or running;
#   7. the new version is installed fresh, checked, and removed;
#   8. sh setup.sh --remove;
#   9. the file list and the checksums of /etc are the same as in step 1, apart from the paths of
#      scripts/lifecycle-excluded.
# The test repository is the published release plus the new packages (scripts/lifecycle-repo.sh,
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
programs="server client"
# package-lib.sh needs a program to be read, and the helpers this script takes from it (boot_system,
# wait_booted, pull_image, system_selected) do not depend on which one it is.
PROGRAM=server
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
. scripts/service-check-lib.sh
. scripts/site-server-lib.sh

platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
for p in $programs; do
    [ -f "dist/lifecycle/$p/published" ] || fail "dist/lifecycle/$p/published does not exist: run make lifecycle-repo first"
    [ -d "dist/lifecycle/$p/repo" ] || fail "dist/lifecycle/$p/repo does not exist: run make lifecycle-repo first"
done
work="$(mktemp -d "$root/dist/lifecycle/run.XXXXXX")"
log="$work/log"
container=""
cleanup() {
    stop_site_server
    if [ -n "$container" ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Runs the command in a shell of its own that knows the program $1 at the version $2: what
# package-lib.sh says about them, what the program's service check says, and the functions of
# the package format. The shell ends this system's run when the command fails, because every
# check reports with fail. Usage: as_program PROGRAM VERSION COMMAND [ARGUMENT...].
as_program() {
    (
        PROGRAM="$1"
        VERSION="$2"
        shift 2
        PACKAGE_DATE="$(sed -n 's/^PACKAGE_DATE=//p' "dist/$PROGRAM/version")"
        export PROGRAM VERSION PACKAGE_DATE
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
# wrote) or as it was published (the tag that scripts/lifecycle-repo.sh wrote down), as v1.2.3.
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

# Runs the package checks of scripts/package-test-lib.sh, which look at the system they run in,
# inside the container $1: the checks named by the other arguments, for the program and version
# of the caller. The repository is mounted at /src, where those scripts read their definitions.
in_system() {
    container_name="$1"
    shift
    docker exec -e PROGRAM -e VERSION -e PACKAGE_DATE -w /src "$container_name" sh -c \
        '. scripts/package-lib.sh; . scripts/package-test-lib.sh; for check in "$@"; do "$check"; done' sh "$@"
}

# What a fresh install does to the service today: it is enabled, starts by itself, runs as its
# own user and does its job. The owner decided that the packages will not start the service on
# install; when that is built, this function is the one place to change, and the steps that
# call it follow.
check_service_after_install() {
    check_starts_by_itself "$1"
    check_user "$1"
    check_answers "$1"
}

# The service of a program that was upgraded is the one that was running: it is running again.
check_service_after_upgrade() {
    must "the service is not active and answering 20 seconds after the upgrade" \
        wait_for 20 active_and_answering "$1"
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
    for p in $programs; do
        as_new "$p" refuse "$p is still installed after it was removed" package_installed "$1"
        as_new "$p" in_system "$1" check_programs_removed
    done
    must "a process of ours is still running" no_process_of_ours "$1"
    echo "ok: nothing of ours is installed or running"
}

# Writes the snapshot of the system into the file $2 on the host.
take_snapshot() {
    docker exec "$1" sh /src/scripts/lifecycle-snapshot.sh >"$2" || fail "the snapshot of the system failed"
}

# One system, in the order of the steps in the header. The caller runs this in a subshell so
# that fail, which every check calls, ends only this system.
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

    echo "step 1: the vanilla system is written down"
    take_snapshot "$c" "$work/before"

    echo "step 2: sh setup.sh"
    must "setup.sh failed" docker exec "$c" sh /site/setup.sh
    as_new server must "refreshing the package index failed" repo_refresh "$c"

    echo "step 3: the published release is installed from the repository"
    for p in $programs; do
        as_published "$p" must "installing the published $p failed" repo_install "$c"
        as_published "$p" in_system "$c" check_versions
        as_published "$p" check_service_after_install "$c"
    done

    echo "step 4: the upgrade to the new packages"
    for p in $programs; do
        as_new "$p" must "upgrading $p failed" repo_upgrade "$c"
        as_new "$p" in_system "$c" check_versions
        as_new "$p" check_service_after_upgrade "$c"
    done

    echo "step 5: one program is removed, the other still works"
    as_new server check_removal "$c"
    as_new client must "the client stopped working when the server was removed" \
        wait_for 10 active_and_answering "$c"

    echo "step 6: the other program is removed"
    as_new client check_removal "$c"
    check_nothing_of_ours "$c"

    echo "step 7: the new version is installed fresh and removed"
    for p in $programs; do
        as_new "$p" must "installing $p failed" repo_install "$c"
        as_new "$p" in_system "$c" check_versions check_links check_config_folders check_extras
        as_new "$p" check_service_after_install "$c"
    done
    for p in $programs; do
        as_new "$p" check_removal "$c"
    done
    check_nothing_of_ours "$c"

    echo "step 8: sh setup.sh --remove"
    must "setup.sh --remove failed" docker exec "$c" sh /site/setup.sh --remove

    echo "step 9: the system is as it was"
    take_snapshot "$c" "$work/after"
    if ! diff "$work/before" "$work/after" >"$work/diff"; then
        cat "$work/diff"
        fail "the system is not as it was before the setup: the lines above differ"
    fi
    echo "ok: the files and the checksums of /etc are as they were"
}

passed=0
failed=0
count=0
systems="$(cat packaging/test-systems)"

# The site is built once the port is known: its address is part of the setup script and of its
# checksum. Both repositories are signed with one set of keys, so one setup script trusts both.
site="$work/site"
start_site_server "$site" "$work"
KEYS_DIR="$root/dist/keys" BASE_URL="http://host.docker.internal:$site_port" SITE_DIR="$site" \
    sh scripts/build-site.sh >"$work/build.log" 2>&1 || { cat "$work/build.log" >&2; exit 1; }
for p in $programs; do cp -R "dist/lifecycle/$p/repo" "$site/$p"; done

# A here-document keeps the counters in this shell; a pipe would run the loop in a subshell.
while read -r format image; do
    # Blank lines and comments are skipped; every other line is a system to test.
    case "$format" in "" | "#"*) continue ;; *) ;; esac
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
    for needed in "scripts/service-test-$format.sh" "scripts/lifecycle-test-$format.sh"; do
        [ -f "$needed" ] || fail "$needed does not exist"
    done

    # A registry failure must not look like a failed lifecycle test.
    # Errexit is off for the call to read its status; pull_image checks every command itself.
    set +e
    pull_image "$platform" "$image"
    pulled=$?
    set -e
    if [ "$pulled" -ne 0 ]; then
        echo "FAIL $format $image"
        echo "     could not download the image $image (3 tries)"
        failed=$((failed + 1))
        continue
    fi

    count=$((count + 1))
    container="splicefs-lifecycle-test-$$-$count"
    # The options of both programs: the server publishes its port. run_options prints whole
    # options and nothing else, so it is left unquoted on purpose.
    options=""
    for p in $programs; do
        options="$options $(as_new "$p" run_options)"
    done
    started=0
    # boot_system is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2086,SC2310
    if boot_system --name "$container" --platform "$platform" --add-host=host.docker.internal:host-gateway \
        -v "$site":/site:ro -v "$root":/src:ro $options "$image" 2>"$log"; then
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
        echo "ok   $format $image"
        passed=$((passed + 1))
    else
        echo "FAIL $format $image"
        tail -n 70 "$log" | sed 's/^/     /'
        failed=$((failed + 1))
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    container=""
done <<LIST
$systems
LIST

echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
