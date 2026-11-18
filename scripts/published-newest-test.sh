#!/bin/sh
# Test of scripts/published-newest.sh: which published package of a program is the newest, the
# one the upgrade tests start from. Runs on the host, no Docker and no network (part of make
# check): the published index is a file of the test, given by INDEX_FILE.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# $1 file name, then the stanzas as "PACKAGE VERSION" lines on the standard input: the part of
# an apt Packages index this script reads.
index() {
    awk '{ printf "Package: %s\nVersion: %s\nArchitecture: amd64\n\n", $1, $2 }' > "$work/$1"
}

# $1 case name, $2 index file, $3 PROGRAM, $4 what must be printed: the version, or "none" when the
# index lists no package of the program (an empty answer would read as a failed read).
newest() {
    # The status of the script is the answer here, so set -e being off inside it changes nothing.
    got="$(INDEX_FILE="$work/$2" sh scripts/published-newest.sh "$3" 2>&1)" || true
    if [ "$got" = "$4" ]; then
        printf 'ok   %s: "%s"\n' "$1" "$got"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$4" "$got"
        failed=$((failed + 1))
    fi
}

index revision <<'LIST'
splicefs-server 0.5.33
splicefs-server 0.5.34
splicefs-server 0.5.34-1
LIST
newest "a revision is newer than its release" revision server 0.5.34-1

# Revisions and the parts of a version are numbers: 10 is more than 9 and 0.5.34 is more than 0.5.9,
# which a sort of the text gets wrong.
index numeric <<'LIST'
splicefs-server 0.5.9
splicefs-server 0.5.34-9
splicefs-server 0.5.34-10
splicefs-server 0.5.34-2
splicefs-server 0.5.4
LIST
newest "numbers are compared as numbers" numeric server 0.5.34-10

index later <<'LIST'
splicefs-server 0.5.34-3
splicefs-server 0.5.35
LIST
newest "the next version is newer than any revision of the one before" later server 0.5.35

# A pre-release is older than its release and newer than the release before.
index pre <<'LIST'
splicefs-server 0.5.33
splicefs-server 1.0.0~rc.2
splicefs-server 1.0.0~rc.10
splicefs-server 1.0.0~beta.1
LIST
newest "a pre-release is newer than the version before" pre server 1.0.0~rc.10

index pre-release <<'LIST'
splicefs-server 1.0.0~rc.1
splicefs-server 1.0.0
splicefs-server 1.0.0~rc.1-1
LIST
newest "a release is newer than its pre-releases" pre-release server 1.0.0

index other <<'LIST'
splicefs-client 9.9.9
splicefs-server 0.5.34
LIST
newest "only the package of the program counts" other server 0.5.34

index none <<'LIST'
splicefs-client 0.5.34
LIST
newest "nothing is published of the program" none server none

: > "$work/empty"
newest "an empty index" empty server none

got="$(INDEX_FILE="$work/missing" sh scripts/published-newest.sh server 2>&1)" && status=0 || status=$?
if [ "$status" -ne 0 ] && printf '%s' "$got" | grep -q 'could not read'; then
    echo "ok   an index that cannot be read stops the script and says so"
else
    printf 'FAIL an index that cannot be read: status %s, %s\n' "$status" "$got"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "published-newest: all cases as expected"
