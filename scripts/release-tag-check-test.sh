#!/bin/sh
# Test of scripts/release-tag-check.sh (part of make check): a run that holds the signing and
# upload keys is for a number tag whose commit is on main, and for nothing else. Runs on the
# host with a local repository as origin, no network.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
failed=0

git_t() {
    git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"
}

git init -q --bare -b main "$tree/origin.git"
git clone -q "$tree/origin.git" "$tree/work" 2> /dev/null
cd "$tree/work"
git_t commit -q --allow-empty -m one
on_main="$(git rev-parse HEAD)"
git push -q origin HEAD:main
git_t commit -q --allow-empty -m two
on_branch="$(git rev-parse HEAD)"
git push -q origin HEAD:refs/heads/side

# $1 case name, $2 the exit status wanted, $3 the ref type, $4 the ref name, $5 the commit, $6 a
# text the error must contain (only for a failure).
check() {
    status=0
    sh "$root/scripts/release-tag-check.sh" "$3" "$4" "$5" > "$tree/out" 2>&1 || status=$?
    if [ "$status" -ne "$2" ]; then
        printf 'FAIL %s: status %s, wanted %s\n' "$1" "$status" "$2"
        sed 's/^/     /' "$tree/out"
        failed=$((failed + 1))
    elif [ "$2" -ne 0 ] && ! grep -q "$6" "$tree/out"; then
        printf 'FAIL %s: the error does not say "%s"\n' "$1" "$6"
        sed 's/^/     /' "$tree/out"
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

check "a number tag on a commit of main" 0 tag 7 "$on_main"
check "a number tag with several digits" 0 tag 1203 "$on_main"
check "a number tag on a commit that is not on main" 1 tag 7 "$on_branch" 'not on main'
check "a number tag on a commit that does not exist" 1 tag 7 0000000000000000000000000000000000000000 'not on main'
check "a version tag is no longer a release" 1 tag v0.4.20 "$on_main" 'not a number'
check "a tag with a suffix is no release" 1 tag 7-rc "$on_main" 'not a number'
check "a number with a leading zero is no release" 1 tag 07 "$on_main" 'not a number'
check "a run on a branch named like a number is refused" 1 branch 7 "$on_main" 'not a tag'
check "no argument is a usage error" 2 '' '' '' 'usage'

# main moves forward after the tag was made: the tagged commit is still on it.
git_t commit -q --allow-empty -m three
git push -q origin HEAD:main
check "a commit that main has moved past is still on main" 0 tag 7 "$on_main"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "release-tag-check checks done"
