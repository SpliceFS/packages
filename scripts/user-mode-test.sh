#!/bin/sh
# check-not-run: needs Docker, the packages in dist/PROGRAM and SERVER_BIN (make user-mode-test)
# Proves that an ordinary user can run the client under their own account, with the commands of
# "Run as yourself" (steps/user-mode-start.sh and steps/user-mode-use.sh, the commands the install
# page of the website shows). In a booted container of the first system of each
# format in packaging/test-systems it installs the client package, starts a real server, adds an
# ordinary user, and as that user runs the documented commands, which give no --config and no cache
# setting: the client starts, mounts a folder of the server in the user's folder, a file reads, and
# the mount goes away again. It proves that the client used the user's own folders: the cluster is
# only in ~/.config/splicefs/client, the cache is in ~/.cache/splicefs, and the control socket is
# in /tmp/splicefs-<uid>, which only the user may enter. Then it proves that nothing of root's was
# touched: the service is neither enabled nor running, the system configuration folder holds what
# it held, and the user owns no file outside their own places.
# Runs on the host (make user-mode-test); it needs Docker. Environment: the version comes from
# dist/client/version (scripts/package-record.sh); SERVER_BIN is the folder that holds the
# programs of the server (splicefsd and splicefsdctl) built for the CPU type of the container;
# PLATFORM and ONLY as for scripts/service-test.sh.
#
# What a container cannot show: that /dev/fuse is there on a host that has not loaded the FUSE
# module (the test host must), and how a login session sets XDG_RUNTIME_DIR; without it the
# control socket is in /tmp/splicefs-<uid>, which is the case that is tested.
# Every check of run_checks is guarded with fail or must, and errexit is off there (see the loop
# below), so a function used in a guarded command line is meant: its status is the answer.
# shellcheck disable=SC2310,SC2312
set -eu

PROGRAM=client
: "${SERVER_BIN:?SERVER_BIN is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
# shellcheck source=server-fixture-lib.sh
. scripts/server-fixture-lib.sh

platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
container=""
cleanup() {
    if [ -n "$container" ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

reader=reader
home="/home/$reader"
config="$home/.config/splicefs/client"
cache="$home/.cache/splicefs"
# The documented steps use the address of the example cluster; the test points it at its server.
EXAMPLE_URL='https://east.example.com/api'
SERVER_URL='http://127.0.0.1:18490/api'

# $1 the container. The documented commands run as the user, in the user's home, as docker exec
# does not start a login session.
as_user() {
    c="$1"
    shift
    docker exec -u "$reader" -e HOME="$home" -w "$home" "$c" "$@"
}

# The user is made the way the system's own tools do it.
add_user() {
    case "$1" in
        apk) docker exec "$2" adduser -D "$reader" ;;
        *) docker exec "$2" useradd -m "$reader" ;;
    esac
}

# No --config: the client and its control program must find the same folders by themselves.
client_answers() {
    as_user "$1" splicefsctl status >/dev/null 2>&1
}

# Status 0 when the folder $2 of the container $1 is owned by the user and has the mode $3.
owned_with_mode() {
    [ "$(docker exec "$1" stat -c '%U %a' "$2")" = "$reader $3" ]
}

# What the client wrote into the user's own folders. The socket folder is in /tmp because docker
# exec starts no login session, so XDG_RUNTIME_DIR is not set.
proves_own_folders() {
    c="$1"
    as_user "$c" test -f "$config/clusters.d/example.yaml" || fail "the cluster is not in $config"
    as_user "$c" test -f "$config/secrets/example" || fail "the password is not in $config"
    [ -n "$(docker exec "$c" find "$cache" -mindepth 1 -user "$reader")" ] || fail "the cache $cache holds nothing of the user"
    uid="$(docker exec "$c" id -u "$reader")"
    owned_with_mode "$c" "/tmp/splicefs-$uid" 700 || fail "/tmp/splicefs-$uid is not the user's, mode 700"
    docker exec "$c" sh -c 'find "$1" -type s | grep -q .' sh "/tmp/splicefs-$uid" ||
        fail "no control socket in /tmp/splicefs-$uid"
}

# The process id of the client of the user, read from /proc, which every system has.
client_pid() {
    docker exec "$1" sh -c '
        uid="$(id -u "$1")"
        for dir in /proc/[0-9]*; do
            [ "$(readlink "$dir/exe" 2>/dev/null)" = "/usr/bin/splicefs" ] || continue
            [ "$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "$dir/status")" = "$uid" ] || continue
            echo "${dir#/proc/}"
            exit 0
        done
        exit 1' sh "$reader"
}

# What the system's configuration folder holds, to compare before and after.
system_files() {
    docker exec "$1" sh -c 'find /etc/splicefs -print | sort'
}

# Files the user owns outside their home, /tmp and /run: there must be none. The mail spool that
# useradd makes is the system's own and not the client's.
stray_files() {
    docker exec "$1" sh -c '
        find / -xdev -user "$1" ! -path "/home/*" ! -path "/tmp/*" ! -path "/run/*" ! -path "/var/tmp/*" ! -path "/var/mail/*" ! -path "/var/spool/mail/*" \
            ! -path /tmp ! -path /run 2>/dev/null' sh "$reader"
}

run_checks() {
    c="$1"
    format="$2"
    must "the system did not finish booting" wait_booted "$format" "$c"
    must "installing the package failed" install_package "$c"
    fusermount="$(docker exec "$c" sh -c 'command -v fusermount3')" || fail "the package did not bring fusermount3"
    docker exec "$c" test -u "$fusermount" || fail "$fusermount is not setuid, as the distribution ships it"
    docker exec "$c" sh -c "$SERVER_FIXTURE" || fail "starting the server failed"
    must "the server does not answer after 20 seconds" wait_for 20 server_answers "$c"
    must "adding the user failed" add_user "$format" "$c"
    before="$(system_files "$c")"

    # The documented commands, with the address of the example cluster replaced. The password is
    # typed on standard input, as the page says.
    docker exec "$c" sh -c 'sed "s|$1|$2|" /steps/user-mode-start.sh >/tmp/start.sh && cp /steps/user-mode-use.sh /tmp/use.sh' \
        sh "$EXAMPLE_URL" "$SERVER_URL" || fail "preparing the documented steps failed"
    printf 'secret\n' | docker exec -i -u "$reader" -e HOME="$home" -w "$home" "$c" sh /tmp/start.sh >"$log" 2>&1 &
    started=$!
    must "the client does not answer after 20 seconds" wait_for 20 client_answers "$c"
    pid="$(client_pid "$c")" || fail "no splicefs process of $reader"

    out="$(as_user "$c" sh /tmp/use.sh)" || fail "the documented use commands failed"
    printf '%s\n' "$out" | grep -qx media || fail "the mount does not list the share: $out"
    printf '%s\n' "$out" | grep -qx hello || fail "the file does not read: $out"
    echo "ok: the user started the client, mounted, read a file and unmounted"
    proves_own_folders "$c"
    echo "ok: the files are in $config, $cache and the user's own socket folder"
    refuse "the mount is still there" as_user "$c" mountpoint -q "$home/files"

    docker exec "$c" kill -TERM "$pid" || fail "stopping the client failed"
    # Waits for the client to end, which is the signal that it is stopped.
    wait "$started" || true
    refuse "the client is still running" client_pid "$c"
    echo "ok: the client stopped"

    refuse "the service is running" service_active "$c"
    refuse "the service is enabled" service_enabled "$c"
    [ "$(system_files "$c")" = "$before" ] || fail "the system configuration folder changed"
    stray="$(stray_files "$c")"
    [ -z "$stray" ] || fail "the user owns files outside their own places: $stray"
    echo "ok: nothing of root's was touched"
}

passed=0
failed=0
count=0
log="$(mktemp)"
trap 'cleanup; rm -f "$log"' EXIT
for format in deb rpm apk; do
    # The first system of the format is the one tested, the same as for the other tests.
    image="$(awk -v f="$format" '$1 == f { print $2; exit }' packaging/test-systems)"
    [ -n "$image" ] || fail "packaging/test-systems has no $format system"
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
    # shellcheck source=/dev/null
    . "scripts/service-test-$format.sh"
    # A registry failure must not look like a failed test; pull_image checks every command itself.
    set +e
    pull_image "$platform" "$image"
    pulled=$?
    set -e
    if [ "$pulled" -ne 0 ]; then
        echo "FAIL $image: could not download it"
        failed=$((failed + 1))
        continue
    fi
    count=$((count + 1))
    container="splicefs-user-mode-test-$$-$count"
    boot_system --name "$container" --platform "$platform" \
        -v "$root/dist/$PROGRAM":/pkg:ro -v "$SERVER_BIN":/srvbin:ro -v "$root/steps":/steps:ro "$image"
    # Errexit is off here on purpose: every command of run_checks is guarded with fail.
    set +e
    (run_checks "$container" "$format")
    checked=$?
    set -e
    if [ "$checked" -eq 0 ]; then
        echo "ok   $image"
        passed=$((passed + 1))
    else
        echo "FAIL $image"
        tail -n 20 "$log" 2>&1 || true
        docker exec "$container" tail -n 20 /tmp/server.log 2>&1 || true
        failed=$((failed + 1))
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    container=""
done

echo "passed: $passed  failed: $failed"
[ "$failed" -gt 0 ] && exit 1
[ "$passed" -gt 0 ] || { echo "no system was tested"; exit 1; }
