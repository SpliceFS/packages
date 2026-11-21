#!/bin/sh
# check-not-run: needs Docker, the Alpine packages in dist/PROGRAM and SERVER_BIN (make fstab-test)
# Proves that a SpliceFS mount can come from the boot mounts of the system: on every Alpine image
# of packaging/test-systems, in a booted container, it installs the client package, runs a real
# server, writes an fstab line for it, and checks that OpenRC's netmount service (which mounts the
# _netdev lines once the network is up) mounts the folder so that a file can be read, and that
# stopping netmount unmounts it. systemd systems are not covered: their mounts are made by
# systemd, which this test does not run. Runs on the host (make fstab-test); it needs Docker.
# Environment: the version comes from dist/client/version (scripts/package-record.sh);
# SERVER_BIN is the folder that holds the programs of the server (splicefsd and splicefsdctl)
# built for the CPU type of the container (the dist/bin/linux-<arch> folder of the server);
# PLATFORM and ONLY as for scripts/package-test.sh.
#
# The client opens its control socket late in this test (CLIENT_DELAY seconds, a wrapper that
# only the test installs), as it does at boot while it connects to its clusters. netmount starts
# the moment the start command of the client returns, so the mount works only when that command
# returns once the client answers, which the OpenRC service waits for (start_post).
#
# What a container cannot show: OpenRC skips netmount at boot in a container, so the order of
# the client service before netmount is only declared (programs/client/openrc/splicefs.initd),
# not run. A virtual machine is needed for that.
set -eu

PROGRAM=client
: "${SERVER_BIN:?SERVER_BIN is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
# install_package and service_start_enable, the same commands the install page documents, run in
# the container with docker exec.
. scripts/service-run-container.sh
. scripts/service-test-apk.sh

platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
container=""
cleanup() {
    if [ -n "$container" ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The real server, and the client's cluster file and fstab line for it.
# shellcheck source=server-fixture-lib.sh
. scripts/server-fixture-lib.sh
# The script runs in the container, so the variables in it are meant to stay unexpanded here.
# shellcheck disable=SC2016
CLIENT_SETUP='
mkdir -p /mnt/files
printf "url: http://127.0.0.1:18490/api\nuser: alice\npassword_file: /etc/splicefs/client/secret\n" \
    >/etc/splicefs/client/clusters.d/test.yaml
printf "secret\n" >/etc/splicefs/client/secret
chmod 600 /etc/splicefs/client/secret
echo "test:/ /mnt/files splicefs _netdev,nofail 0 0" >>/etc/fstab
'

# The delay is the fault injected into the client, not a wait for anything: it makes a start
# command that returns before the client answers show itself every time.
CLIENT_DELAY=3
# The service starts /usr/bin/splicefs and its init script fixes that path, so the wrapper takes
# the place of the program and runs the real one, which keeps its own name, after the delay.
# The script runs in the container, so its variables stay unexpanded here.
# shellcheck disable=SC2016
SLOW_CLIENT='
set -eu
mkdir -p /usr/local/real
mv /usr/bin/splicefs /usr/local/real/splicefs
printf "#!/bin/sh\nsleep %s\nexec /usr/local/real/splicefs \"\$@\"\n" "$1" >/usr/bin/splicefs
chmod 755 /usr/bin/splicefs
'

client_answers() {
    docker exec "$1" splicefsctl status >/dev/null 2>&1
}

mounted() {
    docker exec "$1" mountpoint -q /mnt/files
}

unmounted() {
    ! docker exec "$1" mountpoint -q /mnt/files
}

run_checks() {
    c="$1"
    must "OpenRC did not finish booting" wait_booted apk "$c"
    must "installing the package failed" install_package "$c"
    docker exec "$c" test -x /sbin/mount.splicefs || fail "/sbin/mount.splicefs is missing"
    docker exec "$c" sh -c "$SERVER_FIXTURE$CLIENT_SETUP" || fail "setting up the server and the fstab line failed"
    must "the server does not answer after 20 seconds" wait_for 20 server_answers "$c"
    docker exec "$c" sh -c "$SLOW_CLIENT" sh "$CLIENT_DELAY" || fail "installing the slow client failed"
    must "the documented start command failed" service_start_enable "$c"
    # No wait: netmount asks the client as soon as the start command is over.
    must "the start command returned before the client answered" client_answers "$c"
    # The commands of the install page, after the fstab line.
    docker exec "$c" sh -c 'rc-update add fuse boot && rc-service fuse start' >/dev/null ||
        fail "the documented fuse commands failed"
    docker exec "$c" sh -c 'rc-update add netmount default && rc-service netmount start' >/dev/null ||
        fail "the documented netmount commands failed"
    must "netmount left /mnt/files unmounted" mounted "$c"
    content="$(docker exec "$c" cat /mnt/files/media/hello.txt)" || fail "the file cannot be read"
    [ "$content" = hello ] || fail "the file holds '$content', not 'hello'"
    echo "ok: netmount mounted the fstab line and the file reads"
    docker exec "$c" rc-service netmount stop >/dev/null || fail "netmount did not stop"
    must "stopping netmount left /mnt/files mounted" wait_for 10 unmounted "$c"
    echo "ok: stopping netmount unmounted it"
}

passed=0
failed=0
count=0
systems="$(grep '^apk ' packaging/test-systems)"
while read -r format image; do
    # system_selected is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    system_selected "$format" "$image" || continue
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
    container="splicefs-fstab-test-$$-$count"
    boot_system --name "$container" --platform "$platform" \
        -v "$root/dist/$PROGRAM":"/pkg/$PROGRAM":ro -v "$SERVER_BIN":/srvbin:ro "$image"
    # Errexit is off here on purpose: every command of run_checks is guarded with fail.
    set +e
    (run_checks "$container")
    checked=$?
    set -e
    if [ "$checked" -eq 0 ]; then
        echo "ok   $image"
        passed=$((passed + 1))
    else
        echo "FAIL $image"
        docker exec "$container" tail -n 20 /var/log/splicefs.log /tmp/server.log 2>&1 || true
        failed=$((failed + 1))
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    container=""
done <<LIST
$systems
LIST

echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
