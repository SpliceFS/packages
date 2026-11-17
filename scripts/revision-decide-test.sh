#!/bin/sh
# Test of scripts/revision-decide.sh: when a change to this repository is published as a package
# revision of the current release. Runs on the host, no Docker and no network (part of make
# check): the published index and the package listings are files of the test.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
failed=0

# What is published: the release v1.2.3 and its revision 1.
printf 'Package: splicefs-server\nVersion: 1.2.3\n\nPackage: splicefs-server\nVersion: 1.2.3-1\n\n' > "$work/index"
# A release that is not published yet.
printf 'Package: splicefs-server\nVersion: 1.2.2\n\n' > "$work/index-unpublished"

# A package listing (scripts/upgrade-lib.sh): the program and the changelog change in every
# version, the unit and the install script are the packaging. Arguments: the sums of the four.
listing() {
    printf 'dir 755 root:root - /etc/splicefs\n'
    printf 'file 755 root:root %s /usr/bin/splicefsd\n' "$1"
    printf 'file 644 root:root %s /usr/lib/systemd/system/splicefs-server.service\n' "$2"
    printf 'file 644 root:root %s /usr/share/doc/splicefs-server/CHANGELOG.md\n' "$3"
    printf 'script postinst %s\n' "$4"
}
published="$(listing program-1 unit-1 log-1 post-1)"
new_release="$(listing program-2 unit-1 log-2 post-1)"
new_unit="$(listing program-1 unit-2 log-1 post-1)"
new_script="$(listing program-1 unit-1 log-1 post-2)"
new_file="$(printf '%s\ndir 755 root:root - /var/lib/splicefs' "$published")"

# $1 case name, $2 listing of the new deb, rpm and apk packages (the same text for all three),
# $3 index file, $4 what must be printed on the standard output: "server v1.2.3" or nothing.
decide() {
    dir="$work/case"
    rm -rf "$dir"
    mkdir "$dir"
    for format in deb rpm apk; do
        printf '%s\n' "$published" > "$dir/published-$format"
        printf '%s\n' "$2" > "$dir/built-$format"
    done
    status=0
    got="$(INDEX_FILE="$work/$3" sh scripts/revision-decide.sh server v1.2.3 "$dir" 2> "$work/err")" || status=$?
    if [ "$status" -eq 0 ] && [ "$got" = "$4" ]; then
        reason="$(tail -n 1 "$work/err")"
        printf 'ok   %s: %s (%s)\n' "$1" "${got:-nothing to publish}" "$reason"
    else
        printf 'FAIL %s: status %s, want "%s" got "%s"\n' "$1" "$status" "$4" "$got"
        sed 's/^/     /' "$work/err"
        failed=$((failed + 1))
    fi
}

decide "the packaging is the same" "$published" index ""

# A change of this repository that is no packaging (a test, a document, a workflow) builds the
# same packages, so it is the same listing; a new program and a new changelog are no change.
decide "docs, tests and workflows build the same packages; a new program and changelog are no change" "$new_release" index ""

decide "a changed service unit is a change" "$new_unit" index "server v1.2.3"
decide "a changed install script is a change" "$new_script" index "server v1.2.3"
decide "a new file is a change" "$new_file" index "server v1.2.3"
decide "a release that is not published is not revised" "$new_unit" index-unpublished ""

# One format that differs is enough, and the other two being the same does not hide it.
dir="$work/one"
mkdir "$dir"
for format in deb rpm apk; do
    printf '%s\n' "$published" > "$dir/published-$format"
    printf '%s\n' "$published" > "$dir/built-$format"
done
printf '%s\nmeta Requires: other\n' "$published" > "$dir/built-rpm"
status=0
got="$(INDEX_FILE="$work/index" sh scripts/revision-decide.sh server v1.2.3 "$dir" 2> "$work/err")" || status=$?
if [ "$status" -eq 0 ] && [ "$got" = "server v1.2.3" ] && grep -q 'rpm' "$work/err"; then
    echo "ok   a change in one format alone is a change, and the format is named"
else
    echo "FAIL a change in one format alone"; failed=$((failed + 1))
fi

# A missing listing is an error and never "nothing differs".
rm "$dir/built-apk"
status=0
INDEX_FILE="$work/index" sh scripts/revision-decide.sh server v1.2.3 "$dir" >/dev/null 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] && grep -q 'built-apk' "$work/err"; then
    echo "ok   a missing listing stops the decision"
else
    echo "FAIL a missing listing"; failed=$((failed + 1))
fi

# A program that is not one of this repository is refused.
status=0
INDEX_FILE="$work/index" sh scripts/revision-decide.sh nothing v1.2.3 "$dir" >/dev/null 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] && grep -q 'is not a program of this repository' "$work/err"; then
    echo "ok   an unknown program is refused"
else
    echo "FAIL an unknown program"; failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "revision-decide checks done"
