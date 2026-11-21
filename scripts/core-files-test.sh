#!/bin/sh
# check: core-files.sh: a core dump on the root filesystem is found and names the program that dumped it, and every path asked for is reported
# Test of scripts/core-files.sh on a folder that stands in for the root of a system (CORE_ROOT),
# with a core file made here byte by byte, so it needs no container and no crash (part of make
# check). The core has a note before the process note, as a real one has, so the notes are walked.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
sys="$t/system"
mkdir -p "$sys/usr/lib" "$sys/var/lib/app"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Writes the number $1 as $2 bytes, little-endian, as amd64 and arm64 store it.
le() {
    n="$1"
    i=0
    while [ "$i" -lt "$2" ]; do
        # shellcheck disable=SC2059
        printf "$(printf '\\%03o' $((n % 256)))"
        n=$((n / 256))
        i=$((i + 1))
    done
}
zeros() { head -c "$1" /dev/zero; }
# Writes the text $1 padded with zero bytes to $2 bytes.
padded() { printf '%s' "$1"; zeros $(($2 - ${#1})); }

# A 64-bit core: the ELF header, one PT_NOTE program header, and two notes in the "CORE" name:
# NT_PRSTATUS (1) with an empty body and NT_PRPSINFO (3) with the pid, the program name and the
# command line at their offsets in the body.
fake_core() {
    printf '\177ELF'
    le 2 1; le 1 1; le 1 1; zeros 9
    le 4 2; le 62 2; le 1 4; le 0 8; le 64 8; le 0 8; le 0 4
    le 64 2; le 56 2; le 1 2; le 0 6
    notes=$((20 + 20 + 136))
    le 4 4; le 0 4; le 120 8; le 0 8; le 0 8; le "$notes" 8; le 0 8; le 0 8
    le 5 4; le 0 4; le 1 4; padded CORE 8
    le 5 4; le 136 4; le 3 4; padded CORE 8
    zeros 24; le "$1" 4; zeros 12; padded "$2" 16; padded "$3" 80
}

fake_core 119 systemctl "systemctl daemon-reload" >"$sys/core.119"
# Not core dumps: a library named like one and a core file of another kind.
printf '\177ELF\002\001\001' >"$sys/usr/lib/core.so"
echo "text" >"$sys/var/lib/app/core"

CORE_ROOT="$sys" sh "$root/scripts/core-files.sh" >"$t/out"
expected="/core.119 pid 119 program systemctl: systemctl daemon-reload"
got="$(cat "$t/out")"
[ "$got" = "$expected" ] || fail "expected '$expected', got '$got'"
echo "ok: the core dump is found with its pid, program and command line, other files named core are not"

# The paths of a comparison are each reported, also when they are no core dump (yet): a core
# that the host's handler is still writing, a file of another kind, a file that is gone.
fake_core 119 systemctl "systemctl daemon-reload" >"$sys/core.119"
head -c 40 "$sys/core.119" >"$sys/core.2253"
CORE_ROOT="$sys" sh "$root/scripts/core-files.sh" /core.119 /core.2253 /var/lib/app/core /core.7 >"$t/out"
expected="/core.119 pid 119 program systemctl: systemctl daemon-reload
/core.2253: not a 64-bit ELF core with a process note: 40 bytes, starting 177 E L F
/var/lib/app/core: not a 64-bit ELF core with a process note: 5 bytes, starting t e x t
/core.7: not a file"
got="$(cat "$t/out")"
[ "$got" = "$expected" ] || fail "expected '$expected', got '$got'"
echo "ok: each path that is asked for is reported, with what it is when it is no core dump"

rm "$sys/core.119" "$sys/core.2253"
CORE_ROOT="$sys" sh "$root/scripts/core-files.sh" >"$t/out"
got="$(cat "$t/out")"
[ -z "$got" ] || fail "a system without a core dump printed '$got'"
echo "ok: a system without a core dump prints nothing"
