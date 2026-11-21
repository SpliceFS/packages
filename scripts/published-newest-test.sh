#!/bin/sh
# check: published-newest.sh: the newest package a program has on the package site
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
# Packages are published only for a release, so a name with a revision is not one of ours.
newest "a name with a revision is never the newest" revision server 0.5.34

# The parts of a version are numbers: 0.5.34 is more than 0.5.9, which a sort of the text gets wrong.
index numeric <<'LIST'
splicefs-server 0.5.9
splicefs-server 0.5.34
splicefs-server 0.5.4
LIST
newest "numbers are compared as numbers" numeric server 0.5.34

index later <<'LIST'
splicefs-server 0.5.34-3
splicefs-server 0.5.35
LIST
newest "the next version is newer than a name with a revision" later server 0.5.35

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

# published_is_newer decides whether step 2 of the package test would go down. The library needs the
# variables of a whole run to be sourced, so its two functions are taken out of it.
for function_name in newest_debver published_is_newer; do
    sed -n "/^$function_name() {\$/,/^}\$/p" scripts/published-lib.sh >> "$work/order.sh"
done
[ -s "$work/order.sh" ] || { echo "FAIL: scripts/published-lib.sh has no published_is_newer" >&2; exit 1; }

# $1 case name, $2 the published deb version, $3 the deb version under test, $4 yes or no.
newer() {
    got=no
    ( . "$work/order.sh"; published_is_newer "$2" "$3" ) && got=yes
    if [ "$got" = "$4" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want %s got %s\n' "$1" "$4" "$got"
        failed=$((failed + 1))
    fi
}
newer "a newer published release is newer" 1.2.4 1.2.3 yes
newer "versions are compared as numbers" 1.2.10 1.2.9 yes
newer "the same version is not newer" 1.2.3 1.2.3 no
newer "an older published release is not newer" 1.2.2 1.2.3 no
newer "a published release is newer than a pre-release of it" 1.2.3 1.2.3~rc.1 yes
newer "a published pre-release is older than its release" 1.2.3~rc.1 1.2.3 no
newer "a build that is not exactly a release counts as the release it follows" 1.2.3 1.2.3+dirty no
newer "a build of an older release is older than the published one" 1.2.4 1.2.3+dirty yes

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "published-newest: all cases as expected"
