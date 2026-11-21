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

# What the FreeBSD machine writes by itself while the package test runs (scripts/freebsd-package-test.sh):
# pkg's database and catalogs, the file the second boot runs and the one-shot rc.d script that starts it,
# and the job folders of the machine's own boot hook. Every one of them is left out, and a folder of
# ours next to them is not.
# The folders themselves are compared, so they are in the snapshot before, with nothing in them yet.
for left_out in var/db/pkg var/db/second-boot tmp/out tmp/in usr/local/etc/rc.d; do
    mkdir -p "$sys/$left_out"
done
snapshot before-machine
for left_out in var/db/pkg var/db/second-boot tmp/out tmp/in; do
    echo "written by the machine" >"$sys/$left_out/state"
done
echo "one-shot" >"$sys/usr/local/etc/rc.d/second_boot"
echo "ok" >"$sys/tmp/status"
snapshot after-machine
diff "$t/before-machine" "$t/after-machine" >/dev/null || fail "what the FreeBSD machine writes by itself counted as a change"
echo "ok: the files of pkg, of the second boot and of the machine's job folders do not count"

mkdir -p "$sys/var/db/splicefs"
snapshot ours
if diff "$t/after-machine" "$t/ours" >/dev/null; then fail "a folder of ours next to the left-out ones was not found"; fi
echo "ok: a folder of ours below /var/db is found"
