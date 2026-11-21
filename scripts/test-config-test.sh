#!/bin/sh
# check: programs/server/test-config.sh: the test configuration is written where the documentation says, and found when it is not
# Test of the test configuration of the server (programs/server/test-config.sh), which the package
# test writes in a system the package is installed in before it starts the service. Here the system
# is a folder, with stand-ins for the two commands that need the real system (splicefsdctl and
# chown), so the test needs no Docker and no root (part of make check).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

mkdir "$work/bin"
cat >"$work/bin/splicefsdctl" <<'STAND_IN'
#!/bin/sh
# Hashes the one line it is given the way the real one prints: the line stands in for the salt.
[ "$*" = "hash-password" ] || exit 2
read -r password
printf '$argon2id$v=19$stand-in-for-%s\n' "$password"
STAND_IN
cat >"$work/bin/chown" <<'STAND_IN'
#!/bin/sh
echo "chown $*" >>"$STAND_IN_DIR/calls"
STAND_IN
chmod 755 "$work/bin/splicefsdctl" "$work/bin/chown"

# Runs the functions named by the arguments as the package test runs them in a system, with the
# folders of the system moved under $work/system. Prints what they print.
in_fake_system() {
    PATH="$work/bin:$PATH" STAND_IN_DIR="$work" PROGRAM=server VERSION=v1.2.3 PACKAGE_DATE=20261112 \
        SYSTEM="$work/system" sh -c '
        . scripts/package-lib.sh
        . programs/server/test-config.sh
        confdir="$SYSTEM/etc/splicefs/server"
        datadir="$SYSTEM/var/lib/splicefs/server"
        share_dir="$SYSTEM/srv/media"
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

mkdir -p "$work/system/etc/splicefs/server/conf.d" "$work/system/etc/splicefs/server/shares.d"
# The status of in_fake_system is the answer, so set -e being off inside it changes nothing.
# shellcheck disable=SC2310
in_fake_system write_test_config >"$work/out" || { cat "$work/out"; failed=$((failed + 1)); }

conf="$work/system/etc/splicefs/server"
state="$work/system/var/lib/splicefs/server"
expect "the share is a file of shares.d, named for the share, with the folder" \
    has_line "path: $work/system/srv/media" "$conf/shares.d/media.yaml"
expect "the share folder holds the file the readers will see" has_line hello "$work/system/srv/media/hello.txt"
# The dollar signs of the hash are the text of the file, so the quotes are single on purpose.
# shellcheck disable=SC2016
expect "the user is a file of the state folder, with the hash of the password" \
    has_line 'password_hash: "$argon2id$v=19$stand-in-for-secret"' "$state/shared/users/alice.yaml"
expect "the user may use the share" has_line "shares: [media]" "$state/shared/users/alice.yaml"
expect "the settings folder gets no file: nothing in it is needed" sh -c "[ -z \"\$(ls -A '$conf/conf.d')\" ]"
# The server must be able to write below shared/ (its keys and its node file), and to read the user.
expect "the state folders it made belong to the service user" \
    has_line "chown -R splicefs $state/shared" "$work/calls"

expect "a written configuration passes its check" in_fake_system check_test_config >/dev/null
# The function $1 fails in the fake system, and its message holds the text $2.
fails_saying() {
    # The status of in_fake_system is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if said="$(in_fake_system "$1")"; then return 1; fi
    case "$said" in *"$2"*) return 0 ;; *) return 1 ;; esac
}
rm "$conf/shares.d/media.yaml"
expect "a missing share file is found and named" fails_saying check_test_config "shares.d/media.yaml is missing"
in_fake_system write_test_config >/dev/null
rm "$state/shared/users/alice.yaml"
expect "a missing user file is found and named" fails_saying check_test_config "alice.yaml is missing"

in_fake_system remove_test_data >/dev/null
expect "the test data it made outside the package's folders is removed" sh -c "[ ! -e '$work/system/srv/media' ]"

if [ "$failed" -ne 0 ]; then
    echo "$failed test-config case(s) failed"
    exit 1
fi
echo "test-config: all cases as expected"
