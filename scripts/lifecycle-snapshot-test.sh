#!/bin/sh
# check: lifecycle-snapshot.sh: the files Docker writes leave the comparison, any other change to /etc is found
# Test of scripts/lifecycle-snapshot.sh on a folder that stands in for the root of a system
# (SNAPSHOT_ROOT), so it needs no container (part of make check). Docker writes /etc/hosts,
# /etc/hostname and /etc/resolv.conf itself, again on every restart of a container, so a change
# to them alone must not count, and a change to any other file of /etc must.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
sys="$t/system"
mkdir -p "$sys/etc" "$sys/var/log"
for file in hosts hostname resolv.conf hosts.allow fstab; do
    echo "first $file" >"$sys/etc/$file"
done

fail() { echo "FAIL: $*" >&2; exit 1; }

snapshot() {
    SNAPSHOT_ROOT="$sys" sh "$root/scripts/lifecycle-snapshot.sh" >"$t/$1"
}

snapshot before
grep -qx "/etc/fstab" "$t/before" || fail "the snapshot does not list the files of the folder"

for file in hosts hostname resolv.conf; do
    echo "address after a restart" >"$sys/etc/$file"
done
snapshot after
diff "$t/before" "$t/after" >/dev/null || fail "a change to the files Docker writes counted as a change"
echo "ok: a change to /etc/hosts, /etc/hostname and /etc/resolv.conf alone does not count"

for file in fstab hosts.allow; do
    cp "$sys/etc/$file" "$t/kept"
    echo "changed" >"$sys/etc/$file"
    snapshot changed
    if diff "$t/before" "$t/changed" >/dev/null; then fail "a change to /etc/$file was not found"; fi
    cp "$t/kept" "$sys/etc/$file"
done
echo "ok: a change to another file of /etc is found, also one whose name starts like a left-out one"
