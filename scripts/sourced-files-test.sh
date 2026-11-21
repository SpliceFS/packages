#!/bin/sh
# check: sourced-files-test.sh: a library that is removed or renamed is refused, and each way to write a path
# Test of scripts/sourced-files.sh (part of make check): a copy of this repository passes, and
# the same copy with libraries removed or renamed is refused, naming every script that sources
# them. Small folders of their own cover each form of path the check resolves, so the test does
# not depend on what this repository sources. A run of the check costs about as much as a shell
# start, so a folder holds many cases and the whole output is compared.
# shellcheck disable=SC2016 # the dollar signs of the cases are the text of a script, not ours
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# The sourcing lines of the cases are written with @ for the dot, so that this file holds no
# line the check would read as a real one.
dot="."

# Runs the check in "$work/tree" and keeps its status and output.
check() {
    status=0
    (cd "$work/tree" && sh "$root/scripts/sourced-files.sh") > "$work/out" 2>&1 || status=$?
}

# $1 case name, $2 the exit status wanted, then the texts the output must hold.
holds() {
    name="$1"
    wanted="$2"
    shift 2
    missing=""
    for text in "$@"; do
        grep -F -q -e "$text" "$work/out" || missing="$missing [$text]"
    done
    if [ "$status" -ne "$wanted" ] || [ -n "$missing" ]; then
        printf 'FAIL %s: status %s, wanted %s, output lacks:%s\n' "$name" "$status" "$wanted" "$missing"
        sed 's/^/     /' "$work/out"
        failed=$((failed + 1))
    else
        echo "ok   $name"
    fi
}

# $1 case name, $2 the exit status wanted, $3 the whole output wanted.
exactly() {
    printf '%s\n' "$3" > "$work/wanted"
    if [ "$status" -ne "$2" ] || ! cmp -s "$work/out" "$work/wanted"; then
        printf 'FAIL %s: status %s, wanted %s\n' "$1" "$status" "$2"
        diff "$work/wanted" "$work/out" | sed 's/^/     /' || true
        failed=$((failed + 1))
    else
        echo "ok   $1"
    fi
}

# Starts the folder of a case with one library.
fresh() {
    rm -rf "$work/tree"
    mkdir -p "$work/tree/scripts"
    echo "# a library" > "$work/tree/scripts/lib.sh"
}

# $1 file, $2 a line of it, with @ where the dot of a sourcing line goes.
put() {
    text="$2"
    line=""
    while [ "${text#*@}" != "$text" ]; do
        line="$line${text%%@*}$dot"
        text="${text#*@}"
    done
    printf '%s\n' "$line$text" >> "$work/tree/$1"
}

# The programs of the tree and the formats of packaging/test-systems resolve $defs and $format.
programs_and_formats() {
    mkdir -p "$work/tree/programs/one" "$work/tree/programs/two" "$work/tree/packaging"
    : > "$work/tree/programs/one/program.conf"
    : > "$work/tree/programs/two/program.conf"
    printf '# comment\n\ndeb image\nrpm image\ndeb other\n' > "$work/tree/packaging/test-systems"
}

# A copy of this repository: the files that exist, the way tracked-files.sh reads them.
mkdir "$work/tree"
(cd "$root" && git ls-files | while read -r file; do
    if [ -f "$file" ]; then printf '%s\0' "$file"; fi
done | tar --null -T - -cf -) | tar -xf - -C "$work/tree"

check
exactly "this repository passes" 0 "every sourced file exists"

mv "$work/tree/scripts/package-lib.sh" "$work/package-lib.sh"
check
holds "a library that scripts source is removed: each script is named" 1 \
    "scripts/package-apk.sh:" "scripts/fstab-test.sh:" \
    "sources scripts/package-lib.sh, which does not exist"
if grep -v -F "sources scripts/package-lib.sh, which does not exist" "$work/out"; then
    echo "FAIL a library that is removed: only its own users are named"
    failed=$((failed + 1))
fi
mv "$work/package-lib.sh" "$work/tree/scripts/package-lib.sh"

mv "$work/tree/scripts/published-lib.sh" "$work/tree/scripts/published-lib.old"
mv "$work/tree/programs/server/service-check.sh" "$work/tree/programs/server/service-check.old"
mv "$work/tree/scripts/service-test-rpm.sh" "$work/tree/scripts/service-test-rpm.old"
mv "$work/tree/programs/client/package-test-extra.sh" "$work/tree/programs/client/package-test-extra.old"
check
holds "a library that is renamed, a file of each program and one of each format are refused" 1 \
    "sources scripts/published-lib.sh, which does not exist" \
    "sources programs/server/service-check.sh, which does not exist" \
    "sources scripts/service-test-rpm.sh, which does not exist"
if grep -F -q "package-test-extra" "$work/out"; then
    echo "FAIL a file the script tests for may be missing"
    failed=$((failed + 1))
fi

fresh
programs_and_formats
: > "$work/tree/programs/one/x.sh"
: > "$work/tree/programs/two/x.sh"
: > "$work/tree/scripts/t-deb.sh"
: > "$work/tree/scripts/t-rpm.sh"
put scripts/a.sh '@ scripts/lib.sh'
put scripts/a.sh '@ "$root/scripts/lib.sh"'
put scripts/a.sh '@ "$here/lib.sh"'
put scripts/a.sh '@ "$defs/x.sh"'
put scripts/a.sh '@ "scripts/t-$format.sh"'
put scripts/a.sh '@ "$1"'
put scripts/a.sh '@ "$1/scripts/x.sh"'
put scripts/a.sh '@ "$in/check-lib.sh"'
put scripts/a.sh '@ "$OS_RELEASE"'
put scripts/a.sh '@ /etc/os-release'
put scripts/a.sh 'sh -c "@ /src/$1"'
put scripts/a.sh '# @ scripts/gone.sh'
put scripts/a.sh 'case "$x" in'
put scripts/a.sh '    @ | .. | .PKGINFO) ;;'
put scripts/a.sh 'esac'
put scripts/a.sh 'if [ -f "scripts/opt.sh" ]; then @ "scripts/opt.sh"; fi'
put scripts/a.sh 'if [ ! -f "$defs/opt.sh" ]; then exit 0; fi'
put scripts/a.sh '@ "$defs/opt.sh"'
check
exactly "paths that exist, are handed over at run time, are outside or are tested for pass" 0 \
    "every sourced file exists"

fresh
programs_and_formats
: > "$work/tree/programs/one/x.sh"
: > "$work/tree/scripts/t-deb.sh"
put scripts/a.sh '@ scripts/gone.sh'
put scripts/a.sh '@ "$root/scripts/gone-root.sh"'
put scripts/a.sh '@ "$here/gone-here.sh"'
put scripts/a.sh '@ "$unknown/lib.sh"'
put scripts/a.sh '@ scripts/gone-more.sh || exit 1'
put scripts/a.sh 'if [ -f scripts/lib.sh ]; then @ scripts/gone-then.sh; fi'
put scripts/a.sh "sh -c '@ scripts/gone-quoted.sh; @ scripts/lib.sh'"
put scripts/a.sh 'x=$(@ scripts/gone-subst.sh)'
put scripts/a.sh 'if [ -f "scripts/opt.sh" ]; then :; fi'
put scripts/a.sh '@ scripts/gone-other.sh'
put scripts/a.sh '@ "$defs/x.sh"'
put scripts/a.sh '@ "scripts/t-$format.sh"'
check
exactly "each path that does not exist is named with its file and line" 1 \
    'scripts/a.sh:1: sources scripts/gone.sh, which does not exist
scripts/a.sh:2: sources scripts/gone-root.sh, which does not exist
scripts/a.sh:3: sources scripts/gone-here.sh, which does not exist
scripts/a.sh:4: cannot tell which file "$unknown/lib.sh" is; name it in scripts/sourced-files.sh
scripts/a.sh:5: sources scripts/gone-more.sh, which does not exist
scripts/a.sh:6: sources scripts/gone-then.sh, which does not exist
scripts/a.sh:7: sources scripts/gone-quoted.sh, which does not exist
scripts/a.sh:8: sources scripts/gone-subst.sh, which does not exist
scripts/a.sh:10: sources scripts/gone-other.sh, which does not exist
scripts/a.sh:11: sources programs/two/x.sh, which does not exist
scripts/a.sh:12: sources scripts/t-rpm.sh, which does not exist'

fresh
put scripts/a.sh '@ "$defs/x.sh"'
put scripts/a.sh '@ "scripts/t-$format.sh"'
check
exactly "defs and format with nothing to stand for are refused, not passed" 1 \
    'scripts/a.sh:1: cannot tell which file "$defs/x.sh" is; name it in scripts/sourced-files.sh
scripts/a.sh:2: cannot tell which file "scripts/t-$format.sh" is; name it in scripts/sourced-files.sh'

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
