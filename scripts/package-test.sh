#!/bin/sh
# check-not-run: needs Docker and the packages in dist/server and dist/client (make package-test)
# Tests the new packages of the programs server and client on every system in packaging/test-systems,
# all at the same time, in ONE boot of the server image per system (its service manager is process 1),
# the way a person installs a package file: no repository and no setup script. Every program whose
# folder dist/PROGRAM holds packages is tested in that one boot, the server first; the folder of a
# program is mounted at /pkg/PROGRAM, and a program whose folder is missing or empty is left out
# ("PROGRAM: no packages, left out").
#
# This script is the host's part and does nothing to a system but start it, run the steps in it,
# restart it, ask the server from outside and read what the steps wrote. The steps themselves, and
# what each of them checks, are in scripts/package-test-steps.sh, which runs inside the system with
# what the system has. Per system:
#   1. the container is started with a copy of the repository (read only) at /src, made when the run
#      began, so that a change of the working tree during the run (a file replaced, a branch changed)
#      is not what a later phase reads; the package folders at
#      /pkg/PROGRAM (they hold the published baseline files, which this script fetched once for the
#      whole run from the package site and proved by its signed index, scripts/published-verify.sh),
#      the public signing keys at /keys, and the version of each baseline at /baselines;
#   2. docker exec runs phase 1 of the steps (steps 0 to 4 and the restart of the service);
#   3. a probe container on the network of the system asks the health endpoint of the server at the
#      address of the system and the port of the server, which proves from outside what the firewall
#      rule of step 4 lets through (a program that listens on no port is not asked);
#   4. docker restart restarts the container, the way a machine is rebooted;
#   5. docker exec runs phase 2 (the rest of step 5), the probe asks again, and docker exec runs
#      phase 3 (the steps 7 to 9);
#   6. the output folder of the steps is copied out of the container: its log is printed and its
#      result is "ok" or the line of the step that failed (the host's own line when the probe failed).
# A failing system does not stop the others, so one run shows every system that is broken. Runs on
# the host (make package-test, CI). Environment: the version of each program comes from
# dist/PROGRAM/version, which make packages wrote (scripts/package-record.sh), and a VERSION given
# must be that one for every program in the run; PLATFORM (linux/amd64 or linux/arm64) tests that CPU
# type by emulation, empty means this machine's own; ONLY limits the run to one format or image;
# GO_IMAGE is the image of the probe container (it has curl).
#
# What differs between package formats is in scripts/service-test-<format>.sh and
# scripts/package-test-<format>.sh, which only the steps read; this script needs their files to exist.
# shellcheck disable=SC2154
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
. scripts/package-test-program-lib.sh
. scripts/systems-lib.sh
# Named explicitly because after a run with another platform the local image tag can point
# at the other CPU type, and an empty setting would then silently test the wrong one.
platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
work="$(mktemp -d)"
# What the systems get from the host, read only: the public signing keys of the package site, which
# step 1 gives the package managers of the systems (mounted at /keys, filled by fetch_baselines),
# and the version of each program's baseline (mounted at /baselines, one file for each program).
keys_dir="$work/keys"
baselines="$work/baselines"
mkdir "$keys_dir" "$baselines"
# The container that asks the server from outside, on the network of the system: an image the project
# runs its own tests in, which has curl.
probe_image="${GO_IMAGE:?GO_IMAGE is not set}"
# Where in the system the steps write their log and their result. It is on the system's own disk, which
# a restart keeps, and scripts/lifecycle-excluded leaves it out of the snapshots.
out_dir=/var/tmp/package-test
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

# The programs of a run, in the order they are tested.
all_programs="server client"

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

# What the steps read of the repository, copied once, before any system starts: the systems read it in
# every phase, minutes apart, and a repository that changes in between (an editor or git replacing a
# file) would fail a phase with a file that is not there. The package files are not in it: they are
# mounted from dist/PROGRAM, and only the record of each build is read from the repository. The host reads
# the records from the copy too (record_folder), so that it and the systems read the same ones, and so that
# the record of a fixture, which is no build, has a place that is not dist.
repository_copy="$work/repository"
mkdir -p "$repository_copy/dist"
for copied in scripts programs steps keys packaging; do
    cp -RL "$root/$copied" "$repository_copy/$copied"
done
for copied in $present; do
    [ -f "$root/dist/$copied/version" ] || {
        echo "FAIL: dist/$copied/version does not exist: run make packages first" >&2
        exit 1
    }
    mkdir "$repository_copy/dist/$copied"
    cp "$root/dist/$copied/version" "$repository_copy/dist/$copied/version"
done
record_folder="$repository_copy/dist"

# The programs that are no program under test, only the published package a program under test needs (below).
fixtures=""

# The folder of the host that is mounted at /pkg/PROGRAM: the packages of dist for a program under test, and
# for a fixture a folder of the run that holds only the published file fetched for it.
package_folder() {
    case " $fixtures " in
        *" $1 "*) echo "$work/fixtures/$1" ;;
        *) echo "$root/dist/$1" ;;
    esac
}

# The hook of scripts/package-test-program-lib.sh that runs once the words of the program are set: the
# baseline of the program is read from the package site into its file in $baselines for the systems.
# Also tells where the published package file of the program is.
prepare_baseline() {
    published_dir="$(package_folder "$PROGRAM")/published"
    save_baseline_version
}

# Runs phase $1 of scripts/package-test-steps.sh in the container, as the root of the system, with
# what the steps need to know that the system cannot know itself.
run_phase() {
    docker exec -e FORMAT="$format" -e PLATFORM="$platform" -e PROGRAMS="$present" -e FIXTURES="$fixtures" \
        -e PACKAGE_TEST_OUT="$out_dir" \
        -w /src "$container" sh scripts/package-test-steps.sh "$1"
}

# The service manager of the container is up before a phase starts: after the boot and after the restart.
wait_until_booted() {
    # wait_booted is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_booted "$format" "$container" || {
        echo "--- last 30 lines of the container output"
        docker logs --tail 30 "$container" 2>&1 || true
        fail "the service manager did not finish booting"
    }
}

# Asks the health endpoint of every program of the run that listens on a port, from a probe container
# on the network of the system: the system's own address, which the container runtime may change at a
# restart, so it is read now, and the port and path the service check of the program names. Outside is
# the only place that proves what the firewall lets through. The first answer is the answer: the steps
# of the phase before waited, from inside, until the service worked, so nothing is waited for here.
# On a wrong answer the line of the step is written to $own/outside-failure, for the result, and the
# status is 1. Usage: check_from_outside PHASE (phase 1 or phase 2).
check_from_outside() {
    for outside_program in $present; do
        use_program "$outside_program"
        [ -n "${port:-}" ] || continue
        # The names of the networks of the container, each with its address there; the first is used.
        networks="$(docker inspect -f '{{range $name, $net := .NetworkSettings.Networks}}{{$name}} {{$net.IPAddress}} {{end}}' "$container")" ||
            fail "docker inspect failed"
        read -r network address _ <<ADDRESS
$networks
ADDRESS
        url="https://$address:$port$health_path"
        asked="answers 200 on $health_path from outside, after $1"
        code="$(docker run --rm --network "$network" "$probe_image" \
            curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
        if [ "$code" != 200 ]; then
            echo "step 5: $outside_program: $asked: $url gave ${code:-nothing}" >"$own/outside-failure"
            return 1
        fi
        echo "ok: $outside_program: $asked ($url, from a container on the network $network)"
    done
}

# The three phases with the restart between phases 1 and 2 and the question from outside after each of
# them; the status is that of the first that fails. The caller runs this in a subshell so that fail
# ends only this system.
run_phases() {
    wait_until_booted
    # run_phase and check_from_outside are one command each whose status is the answer, so set -e being
    # off inside them changes nothing.
    # shellcheck disable=SC2310
    run_phase phase1 && check_from_outside "phase 1" || return 1
    docker restart "$container" >/dev/null || fail "docker restart failed"
    wait_until_booted
    # shellcheck disable=SC2310
    run_phase phase2 && check_from_outside "phase 2" || return 1
    run_phase phase3
}

# One system, in a container and a folder of its own: number $3 of the list. It runs in a process of
# its own, so the functions of its format, sourced there, are its own too.
# Usage: test_system FORMAT IMAGE NUMBER.
test_system() {
    format="$1"
    image="$2"
    container="$prefix-$3"
    own="$work/system-$3"
    mkdir "$own"
    log="$own/log"
    started=0
    # The folder of each program is mounted at /pkg/PROGRAM.
    set -- --name "$container" --platform "$platform" -v "$repository_copy":/src:ro -v "$keys_dir":/keys:ro \
        -v "$baselines":/baselines:ro
    for system_program in $present $fixtures; do
        mounted_folder="$(package_folder "$system_program")"
        set -- "$@" -v "$mounted_folder":"/pkg/$system_program":ro
    done
    # boot_system is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if boot_system "$@" "$image" 2>"$log"; then
        started=1
    fi

    # Errexit is switched off here on purpose: a failing phase must end only this system, not the
    # whole run.
    checked=1
    if [ "$started" -eq 1 ]; then
        set +e
        (run_phases) >>"$log" 2>&1
        checked=$?
        set -e
        # The output of the steps is read after the last phase that ran, also when it failed.
        mkdir "$own/out"
        docker cp "$container:$out_dir/." "$own/out" >>"$log" 2>&1 || true
        if [ -f "$own/out/log" ]; then cat "$own/out/log" >>"$log"; fi
        # A failed question from outside is the result: the steps knew nothing of it.
        if [ -f "$own/outside-failure" ]; then cp "$own/outside-failure" "$own/out/result"; fi
    fi
    cat "$log"
    result="$(cat "$own/out/result" 2>/dev/null)" || result="no result was written"
    if [ "$checked" -eq 0 ] && [ "$result" = ok ]; then
        echo "ok   $format $image"
    else
        # The result names the step the steps stopped in; when they wrote none, there is no step to name.
        case "$result" in
            "step "*)
                reached="${result#step }"
                reached=" (step ${reached%%:*})"
                ;;
            *) reached="" ;;
        esac
        echo "FAIL $format $image$reached"
        echo "     $result"
        checked=1
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$checked"
}

# Choosing the first program is what sources scripts/package-lib.sh, which has the helpers every
# step below uses (fail, must, system_selected, boot_system).
use_program "${present%% *}"

# A program that mounts from the server of the same system (its service check says it needs the cluster
# certificate) has nothing to mount from in a run without packages of the server: the newest published
# server package is installed in step 3 as its fixture. The fixture is fetched and proven like a baseline
# and mounted at /pkg/PROGRAM, and its record, which names the published version as its version, is
# written in the copy of the repository, the one place no build is needed for.
case " $present " in
    *" server "*) ;;
    *)
        for mounting_program in $present; do
            use_program "$mounting_program"
            if [ "${needs_cluster_certificate:-no}" = yes ]; then fixtures=server; fi
        done
        ;;
esac
for fixture_program in $fixtures; do
    fixture_newest="$(sh scripts/published-newest.sh "$fixture_program")" ||
        fail "could not read the newest published package of $fixture_program from $site_root"
    [ "$fixture_newest" != "$nothing_published" ] ||
        fail "no package of $fixture_program is published and dist/$fixture_program has none: the $present has no $fixture_program to mount from"
    mkdir -p "$record_folder/$fixture_program"
    (
        PROGRAM="$fixture_program"
        VERSION="$(package_release_of_debver "$fixture_newest")"
        UPGRADE_FROM="$fixture_newest"
        write_package_record
    )
    echo "$fixture_program: no packages; the newest published $fixture_program ($fixture_newest) is the fixture of the $present"
done

systems="$(cat packaging/test-systems)"
selected=""
# A here-document keeps the list in this shell; a pipe would run the loop in a subshell.
while read -r format image; do
    # Blank lines and comments are skipped; every other line is a system to test.
    case "$format" in "" | "#"*) continue ;; *) ;; esac
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
    for needed in "scripts/service-test-$format.sh" "scripts/package-test-$format.sh"; do
        [ -f "$needed" ] || fail "$needed does not exist"
    done
    selected="$selected$format $image
"
done <<LIST
$systems
LIST

# Downloads the signing keys of the site once, and the published package file of every format that is
# tested, for each program of the run, once for all the systems of the format. The keys are proven to
# be the repository's keys, a package file by the signed index of the site. A download that fails ends
# the run before any system starts: it is not a failure of the package. Choosing the program is what
# reads its baseline from the site, for the systems too.
fetch_baselines() {
    for baseline_program in $present $fixtures; do
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
