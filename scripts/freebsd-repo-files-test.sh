#!/bin/sh
# check: freebsd-repo-files.sh: the input archive of a FreeBSD machine holds the key and is removed
# Host test of freebsd-repo-files.sh: the input archive of a machine holds the private key, and
# remove-input leaves nothing of it behind.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
    echo "FAIL: $1" >&2
    exit 1
}
mkdir -p "$work/out" "$work/keys"
echo private >"$work/keys/splicefs.rsa"
echo public >"$work/keys/splicefs.rsa.pub"
export OUT="$work/out" KEYS="$work/keys"
sh "$root/scripts/freebsd-repo-files.sh" input 15 freebsd-input/15.1.tar
[ -f "$work/out/freebsd-input/15.1.tar" ] || fail "input made no archive"
tar -tf "$work/out/freebsd-input/15.1.tar" | grep -q 'keys/splicefs.rsa$' || fail "the archive holds no key"
sh "$root/scripts/freebsd-repo-files.sh" remove-input freebsd-input/15.1.tar
[ ! -e "$work/out/freebsd-input" ] || fail "remove-input left $work/out/freebsd-input behind"
echo "freebsd-repo-files: the input archive is made and removed"
