#!/bin/sh
# check: programs/client/test-config.sh: the cluster, the mount and the password are written where the documentation says, the cluster key is the server's, and the served certificate is checked against it
# Test of the test configuration of the client (programs/client/test-config.sh), which the package test
# writes in a system the package is installed in before it starts the service. Here the system is a
# folder, with stand-ins for the commands that need the real system (splicefsdctl, splicefs and openssl),
# so the test needs no Docker and no root (part of make check). The real TLS tool is proven in a system by
# the package test itself; here openssl only answers what the stand-in is told to, to show what the check
# does with each answer.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
system="$work/system"
mkdir -p "$system/out" "$system/etc/clusters.d" "$system/etc/mounts.d" "$system/state" "$work/bin"

cat >"$work/bin/splicefsdctl" <<'STAND_IN'
#!/bin/sh
# Stands in for the control program of the server: cluster init makes the key (and fails when
# STAND_IN_INIT_FAILS is set), cluster show prints the line a client needs (STAND_IN_SHOW says what).
case "$*" in
    "cluster init")
        echo "splicefsdctl $*" >>"$STAND_IN_DIR/calls"
        [ -z "${STAND_IN_INIT_FAILS:-}" ]
        ;;
    "cluster show")
        echo "splicefsdctl $*" >>"$STAND_IN_DIR/calls"
        echo "${STAND_IN_SHOW:-cluster_key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}"
        ;;
    *) exit 2 ;;
esac
STAND_IN
cat >"$work/bin/splicefs" <<'STAND_IN'
#!/bin/sh
# Stands in for the client: config check accepts the configuration unless STAND_IN_CHECK_FAILS is set.
echo "splicefs $*" >>"$STAND_IN_DIR/calls"
[ "$*" = "config check" ] && [ -z "${STAND_IN_CHECK_FAILS:-}" ]
STAND_IN
cat >"$work/bin/openssl" <<'STAND_IN'
#!/bin/sh
# Stands in for the TLS tool: it prints a certificate for s_client and x509, a listing of the parts for
# asn1parse (the certificate, the part that is signed at offset 4, the signature at 329), writes files
# for the parts, and verifies the signature unless STAND_IN_BAD_SIGNATURE is set. STAND_IN_NO_SERVER
# makes s_client print nothing, as it does when nothing answers.
echo "openssl $*" >>"$STAND_IN_DIR/calls"
case "$1" in
    s_client) [ -n "${STAND_IN_NO_SERVER:-}" ] || echo "certificate" ;;
    x509)
        read -r pem
        [ -n "$pem" ] || exit 1
        echo "$pem"
        ;;
    asn1parse)
        case "$*" in
            *-strparse*)
                while [ "$#" -gt 1 ]; do
                    [ "$1" = -out ] && echo part >"$2"
                    shift
                done
                ;;
            *)
                echo "    0:d=0  hl=4 l= 403 cons: SEQUENCE"
                echo "    4:d=1  hl=4 l= 325 cons: SEQUENCE"
                echo "  329:d=1  hl=2 l=  71 prim: BIT STRING"
                ;;
        esac
        ;;
    base64) cat >/dev/null ;;
    pkeyutl) [ -z "${STAND_IN_BAD_SIGNATURE:-}" ] ;;
    *) exit 2 ;;
esac
STAND_IN
chmod 755 "$work/bin/splicefsdctl" "$work/bin/splicefs" "$work/bin/openssl"

# Runs the functions named by the arguments as the package test runs them in a system, with the folders
# of the system moved under $system. Prints what they print.
in_fake_system() {
    PATH="$work/bin:$PATH" STAND_IN_DIR="$system" PROGRAM=client VERSION=v1.2.3 PACKAGE_DATE=20261112 \
        SYSTEM="$system" PACKAGE_TEST_OUT="$system/out" OWN_ADDRESS=172.17.0.2 sh -c '
        . scripts/package-lib.sh
        . programs/client/test-config.sh
        confdir="$SYSTEM/etc"
        datadir="$SYSTEM/state"
        mount_target="$SYSTEM/mnt/media"
        for each in "$@"; do "$each"; done' sh "$@" 2>&1
}

# $1 what is checked, then the command that must succeed.
expect() {
    name="$1"
    shift
    if "$@"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        failed=$((failed + 1))
    fi
}
has_line() { grep -qxF -e "$1" "$2"; }
# The function $1 fails in the fake system, and its message holds the text $2.
fails_saying() {
    # The status of in_fake_system is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if said="$(in_fake_system "$1")"; then return 1; fi
    case "$said" in *"$2"*) return 0 ;; *) return 1 ;; esac
}
key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

# The command $1 runs with the stand-in flag $2 set, in a shell of its own.
with_flag() {
    (
        export "$2"
        "$1" "$3" "$4"
    )
}
quietly() { "$@" >/dev/null; }
mode_of() { ls -ld "$1" | cut -c1-10; }

# The status of in_fake_system is the answer, so set -e being off inside it changes nothing.
# shellcheck disable=SC2310
in_fake_system write_test_config >"$work/out" || { cat "$work/out"; failed=$((failed + 1)); }
expect "the key is made on the server before it is shown" \
    sh -c "[ \"\$(sed -n 1p '$system/calls')\" = 'splicefsdctl cluster init' ] && [ \"\$(sed -n 2p '$system/calls')\" = 'splicefsdctl cluster show' ]"
expect "the cluster is the server of the system by its address, with the user and the key of the server" \
    sh -c "grep -qxF 'url: https://172.17.0.2:8480/api' '$system/etc/clusters.d/test.yaml' &&
        grep -qxF 'user: alice' '$system/etc/clusters.d/test.yaml' &&
        grep -qxF 'cluster_key: $key' '$system/etc/clusters.d/test.yaml'"
expect "the cluster names the password file" has_line "password_file: $system/state/password" "$system/etc/clusters.d/test.yaml"
expect "the password file holds the password of the user" has_line secret "$system/state/password"
expect "the password file is readable by its owner only" test "$(mode_of "$system/state/password")" = "-rw-------"
expect "the mount is the share of the cluster, at the folder" \
    sh -c "grep -qxF 'cluster: test' '$system/etc/mounts.d/test.yaml' && grep -qxF 'path: /media' '$system/etc/mounts.d/test.yaml' &&
        grep -qxF 'target: $system/mnt/media' '$system/etc/mounts.d/test.yaml'"
expect "the folder the share is mounted at is there" test -d "$system/mnt/media"

expect "a written configuration passes its check" quietly in_fake_system check_test_config
expect "the client's own check of the configuration is asked" has_line "splicefs config check" "$system/calls"
expect "a configuration the client refuses is named" \
    with_flag fails_saying STAND_IN_CHECK_FAILS=1 check_test_config "does not accept the test configuration"
rm "$system/etc/mounts.d/test.yaml"
expect "a missing mount file is found and named" fails_saying check_test_config "mounts.d/test.yaml is missing"

expect "a failed cluster init stops the writing, with its name" \
    with_flag fails_saying STAND_IN_INIT_FAILS=1 write_test_config "splicefsdctl cluster init failed"
expect "a key line that is not one is named" \
    with_flag fails_saying "STAND_IN_SHOW=nothing here" write_test_config "not a cluster_key line"

expect "the certificate the server serves is checked against the cluster key" \
    in_fake_system served_certificate_is_signed_by_cluster_key
expect "a certificate the cluster key did not sign is refused" \
    with_flag fails_saying STAND_IN_BAD_SIGNATURE=1 served_certificate_is_signed_by_cluster_key ""
expect "a server that serves nothing is refused" \
    with_flag fails_saying STAND_IN_NO_SERVER=1 served_certificate_is_signed_by_cluster_key ""

in_fake_system remove_test_data >/dev/null
expect "the folder the share was mounted at is removed, with the folder above it that the test made" \
    sh -c "[ ! -e '$system/mnt' ]"

if [ "$failed" -ne 0 ]; then
    echo "$failed client test-config case(s) failed"
    exit 1
fi
echo "client test-config: all cases as expected"
