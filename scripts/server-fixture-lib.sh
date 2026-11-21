# shellcheck shell=sh
# Sourced by the tests that need a real server in a container (scripts/fstab-test.sh and
# scripts/user-mode-test.sh). The server is a fixture of those tests, not a package under test,
# so it is started the plain way: one share, media, holding hello.txt, and one user, alice with
# the password secret, in plain HTTP on the loopback address. The programs, splicefsd and
# splicefsdctl (which makes the user), are read from /srvbin, which the test mounts. SERVER_BIN
# is always the folder of a release that has both: scripts/release-bin.sh refuses one that lacks a
# program of program.conf, so no older release reaches this fixture. A release whose splicefsdctl
# has no user add (before user files were named by the user id) gets the user file of that time.

# The script runs in the container, so the variables in it are meant to stay unexpanded here.
# SERVER_FIXTURE is used by the scripts that source this file.
# shellcheck disable=SC2016,SC2034
SERVER_FIXTURE='
set -eu
mkdir -p /srv/data /srv/etc/conf.d /srv/etc/shares.d /srv/state/shared/users
echo hello >/srv/data/hello.txt
if /srvbin/splicefsdctl user add --help >/dev/null 2>&1; then
    printf "secret\n" | /srvbin/splicefsdctl user add --state /srv/state --share media alice >/dev/null
else
    hash="$(printf "secret\n" | /srvbin/splicefsdctl hash-password)"
    printf "password_hash: \"%s\"\nshares: [media]\n" "$hash" >/srv/state/shared/users/alice.yaml
fi
printf "listen:\n  - address: 127.0.0.1\n    port: 18490\n    plain: true\ncluster:\n  node: n1\n  url: \"http://127.0.0.1:18490/api\"\n" \
    >/srv/etc/conf.d/10-server.yaml
printf "path: /srv/data\n" >/srv/etc/shares.d/media.yaml
nohup /srvbin/splicefsd --config /srv/etc --state /srv/state >/tmp/server.log 2>&1 &
'

# Status 0 when the server of the container $1 answers. Alpine ships wget, other systems may ship
# curl, and the rest have only bash, which can open the port; a connection is the answer there.
server_answers() {
    docker exec "$1" sh -c '
        url=http://127.0.0.1:18490/api/v1/health
        if command -v wget >/dev/null 2>&1; then wget -qO /dev/null "$url"
        elif command -v curl >/dev/null 2>&1; then curl -fs -o /dev/null "$url"
        else bash -c "exec 3<>/dev/tcp/127.0.0.1/18490"
        fi'
}
