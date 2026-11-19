#!/bin/sh
# check: next-revision.sh: the revision a build needs to upgrade what is published
# Test of scripts/next-revision.sh: which revision a build of a program version needs to be an
# upgrade of what is published. Runs on the host, no Docker and no network (part of make
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

# $1 case name, $2 index file, $3 PROGRAM, $4 VERSION, $5 the revision that must be printed.
next() {
    # The status of the script is the answer here, so set -e being off inside it changes nothing.
    got="$(INDEX_FILE="$work/$2" sh scripts/next-revision.sh "$3" "$4" 2>&1)" || true
    if [ "$got" = "$5" ]; then
        printf 'ok   %s: %s\n' "$1" "$got"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$5" "$got"
        failed=$((failed + 1))
    fi
}

index none <<'LIST'
splicefs-server 0.5.33
splicefs-server 0.5.33-4
LIST
next "the version is not published, so it is revision 0" none server v0.5.34 0

index plain <<'LIST'
splicefs-server 0.5.33
splicefs-server 0.5.34
LIST
next "the release is published, so the next is revision 1" plain server v0.5.34 1

index several <<'LIST'
splicefs-server 0.5.34
splicefs-server 0.5.34-1
splicefs-server 0.5.34-2
splicefs-server 0.5.35
LIST
next "revision 2 is the highest, so the next is 3" several server v0.5.34 3

# Revisions are numbers: 10 is higher than 9, which a sort of the text would get wrong.
index numeric <<'LIST'
splicefs-server 0.5.34-9
splicefs-server 0.5.34-10
splicefs-server 0.5.34-2
LIST
next "revision 10 is higher than 9" numeric server v0.5.34 11

# Only the version asked for counts, whole: not another version that starts the same, not a
# pre-release of it, and not the version of another package of the same index.
index others <<'LIST'
splicefs-server 0.5.340
splicefs-server 0.5.34~rc.1-5
splicefs-server 0.5.3-9
splicefs-client 0.5.34-7
LIST
next "other versions and other packages do not count" others server v0.5.34 0

index pre <<'LIST'
splicefs-server 0.5.34~rc.1
splicefs-server 0.5.34~rc.1-1
splicefs-server 0.5.34-3
LIST
next "a pre-release has its own revisions" pre server v0.5.34-rc.1 2

index client <<'LIST'
splicefs-server 0.5.34-4
splicefs-client 0.5.34-1
LIST
next "each program has its own revisions" client client v0.5.34 2

# Nothing published at all is not an error either: this is what the first release sees.
: > "$work/empty"
next "an empty index" empty server v0.5.34 0

got="$(INDEX_FILE="$work/missing" sh scripts/next-revision.sh server v0.5.34 2>&1)" && status=0 || status=$?
if [ "$status" -ne 0 ] && printf '%s' "$got" | grep -q 'could not read'; then
    echo "ok   an index that cannot be read stops the script and says so"
else
    printf 'FAIL an index that cannot be read: status %s, %s\n' "$status" "$got"
    failed=$((failed + 1))
fi

got="$(INDEX_FILE="$work/plain" sh scripts/next-revision.sh server 1.2 2>&1)" && status=0 || status=$?
if [ "$status" -ne 0 ] && printf '%s' "$got" | grep -q 'is not vMAJOR.MINOR.PATCH'; then
    echo "ok   a version that is not a release is refused"
else
    printf 'FAIL a version that is not a release: status %s, %s\n' "$status" "$got"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "next-revision: all cases as expected"
