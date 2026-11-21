#!/bin/sh
# check: release-published.sh: whether the packages of a release are already on the package site
# Test of scripts/release-published.sh: whether the deb version of a release of a program is in
# the published apt index, which is what stops a program from being published again. Runs on the
# host, no Docker and no network (part of make check): the published index is a file of the
# test, given by INDEX_FILE.
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

# $1 case name, $2 index file, $3 PROGRAM, $4 the release tag, $5 what must be printed.
answer() {
    # The status of the script is not the answer here, so set -e being off inside it changes nothing.
    got="$(INDEX_FILE="$work/$2" sh scripts/release-published.sh "$3" "$4" 2>&1)" || true
    if [ "$got" = "$5" ]; then
        printf 'ok   %s: %s\n' "$1" "$got"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$5" "$got"
        failed=$((failed + 1))
    fi
}

index listed <<'LIST'
splicefs-server 0.5.33
splicefs-server 0.5.34
splicefs-client 0.5.35
LIST
answer "the version of the release is in the index" listed server v0.5.34 published
answer "a newer release is not in the index" listed server v0.5.35 new
answer "the package of another program does not count" listed client v0.5.34 new
answer "the version of the other program is its own" listed client v0.5.35 published

index pre <<'LIST'
splicefs-server 1.0.0~rc.1
LIST
answer "a pre-release is its own version" pre server v1.0.0-rc.1 published
answer "the release is not its pre-release" pre server v1.0.0 new

# Only the whole version counts: a prefix of a published version is not published.
index prefix <<'LIST'
splicefs-server 0.5.34
LIST
answer "a prefix of a published version is not published" prefix server v0.5.3 new

: > "$work/empty"
answer "an empty index lists nothing" empty server v0.5.34 new

# $1 case name, $2 the index file, $3 the tag, $4 the words the message must hold.
refused() {
    got="$(INDEX_FILE="$work/$2" sh scripts/release-published.sh server "$3" 2>&1)" && status=0 || status=$?
    if [ "$status" -ne 0 ] && printf '%s' "$got" | grep -q "$4"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: status %s, %s\n' "$1" "$status" "$got"
        failed=$((failed + 1))
    fi
}
# A failed read must never read as "not published": the program would be published again.
refused "an index that cannot be read stops the script and says so" missing v0.5.34 'could not read'
refused "a tag that is not a version stops the script and says so" listed latest 'is not vMAJOR'

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "release-published: all cases as expected"
