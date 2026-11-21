#!/bin/sh
# check: own_address of the Linux adapters: the address is the first one getent gives that is not a loopback one
# Test of own_address as the Linux adapters scripts/service-systemd-lib.sh (deb and rpm) and
# scripts/service-test-apk.sh (Alpine) have it. It is one question to the same database, so the
# function is one copy, in scripts/service-linux-lib.sh, which both of them source. getent is a
# stand-in on the PATH that prints the text of glibc's and musl's ahostsv4, so the test needs no
# container and runs in milliseconds (part of make check). FreeBSD asks its own tools:
# scripts/service-test-pkg-test.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
# The adapter of the systemd formats reads it when it is sourced.
# shellcheck disable=SC2034
program=splicefs-test
machine="$(uname -n)"

# The text is in the file $GETENT_OUT, which each case writes; no file, or an empty one, is a name that
# does not resolve: no output and status 2, as getent has it.
mkdir "$work/bin"
cat >"$work/bin/getent" <<'STAND_IN'
#!/bin/sh
echo "getent $*" >> "$CALLS"
[ -s "$GETENT_OUT" ] || exit 2
cat "$GETENT_OUT"
STAND_IN
chmod 755 "$work/bin/getent"
CALLS="$work/calls"
GETENT_OUT="$work/getent-out"
export CALLS GETENT_OUT

# $1 what is checked, $2 the address wanted, which is nothing when no address is wanted.
check_address() {
    : >"$work/calls"
    got="$(PATH="$work/bin:$PATH" own_address 2>&1)"
    asked="$(cat "$work/calls")"
    if [ "$got" = "$2" ] && [ "$asked" = "getent ahostsv4 $machine" ]; then printf 'ok   %s: %s\n' "$adapter" "$1"; else
        printf 'FAIL %s: %s: want "%s" asked of "ahostsv4 %s", got "%s" asked "%s"\n' "$adapter" "$1" "$2" "$machine" "$got" "$asked"
        failed=$((failed + 1))
    fi
}

# The one copy is in the shared file, and the adapters hold none of their own.
shared=scripts/service-linux-lib.sh
for adapter in scripts/service-systemd-lib.sh scripts/service-test-apk.sh; do
    if grep -q '^own_address()' "$adapter" || ! grep -q '^own_address()' "$shared"; then
        printf 'FAIL %s: own_address is not the one copy of %s\n' "$adapter" "$shared"
        failed=$((failed + 1))
    else
        printf 'ok   %s: own_address is the one copy of %s\n' "$adapter" "$shared"
    fi
done

# The cases are the same for each adapter, which is sourced by name: the files a script sources are
# proven to exist by scripts/sourced-files.sh, which cannot read a variable. The function is taken
# away before each adapter is sourced, so that each one has to bring it.
cases() {
    adapter="$1"
    printf '172.17.0.2      STREAM box\n172.17.0.2      DGRAM\n172.17.0.2      RAW\n' >"$GETENT_OUT"
    check_address "one address, as in a container" 172.17.0.2

    printf '127.0.1.1       STREAM box\n127.0.1.1       DGRAM\n127.0.1.1       RAW\n172.17.0.2      STREAM box\n172.17.0.2      DGRAM\n172.17.0.2      RAW\n' >"$GETENT_OUT"
    check_address "the loopback address that installers write for the name is skipped" 172.17.0.2

    printf '127.0.0.1       STREAM box\n10.1.2.3        STREAM box\n10.1.2.4        STREAM box\n' >"$GETENT_OUT"
    check_address "the first address that is not a loopback one is the answer" 10.1.2.3

    printf '127.0.0.1       STREAM box\n127.0.0.1       DGRAM\n127.0.0.1       RAW\n' >"$GETENT_OUT"
    check_address "only a loopback address is no address" ""

    : >"$GETENT_OUT"
    check_address "a name that does not resolve is no address" ""
}

unset -f own_address
. scripts/service-systemd-lib.sh
cases scripts/service-systemd-lib.sh
unset -f own_address
. scripts/service-test-apk.sh
cases scripts/service-test-apk.sh

[ "$failed" -eq 0 ]
echo "own_address of the Linux adapters: all cases as expected"
