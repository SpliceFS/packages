#!/bin/sh
# check: list-checked-tests.sh: every *-test.sh says whether make check runs it, and none is left out
# Test of scripts/list-checked-tests.sh (part of make check): a test script that says "# check:
# DESCRIPTION" on its second line is listed with that description, one that says "# check-not-run:
# REASON" is not, and one that says neither is refused by name, wherever in the repository it is.
# Runs on the host, on a fixture tree. It also proves that check.sh names no test itself.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
failed=0

mkdir -p "$tree/scripts"
cp "$root/scripts/list-checked-tests.sh" "$tree/scripts/"

# $1 the path of the test script in the fixture, $2 its second line, "-" for none.
script() {
    mkdir -p "$(dirname "$tree/$1")"
    printf '#!/bin/sh\n' > "$tree/$1"
    [ "$2" = - ] || printf '%s\n' "$2" >> "$tree/$1"
    printf 'exit 0\n' >> "$tree/$1"
}

# $1 case name, $2 the exit status wanted, $3 the standard output wanted, whole, $4 text that the
# standard error must contain, if any.
list() {
    status=0
    got="$(sh "$tree/scripts/list-checked-tests.sh" 2> "$tree/err")" || status=$?
    if [ "$status" -ne "$2" ]; then
        printf 'FAIL %s: status %s, wanted %s\n' "$1" "$status" "$2"
        failed=$((failed + 1))
    elif [ "$got" != "$3" ]; then
        printf 'FAIL %s: wanted <%s> got <%s>\n' "$1" "$3" "$got"
        failed=$((failed + 1))
    elif [ -n "${4:-}" ] && ! grep -q -- "$4" "$tree/err"; then
        printf 'FAIL %s: the error does not say "%s"\n' "$1" "$4"
        sed 's/^/     /' "$tree/err"
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

list "a tree with no test script is an error" 1 '' 'no \*-test.sh script found'

script scripts/b-test.sh '# check: b does this'
script scripts/a-test.sh '# check: a does that, then this'
list "a test is listed with its description, in the order of the names" 0 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this'

script scripts/docker-test.sh '# check-not-run: needs Docker'
list "a test that says it is not run is not listed" 0 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this'

script scripts/silent-test.sh -
list "a test that says nothing is refused by name, and the others are still listed" 1 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this' 'scripts/silent-test.sh'
rm "$tree/scripts/silent-test.sh"

script scripts/late-test.sh '# a comment first'
printf '# check: too late\n' >> "$tree/scripts/late-test.sh"
list "the line is the second one: the same line further down is refused" 1 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this' 'scripts/late-test.sh'
rm "$tree/scripts/late-test.sh"

script scripts/empty-test.sh '# check:'
list "a description that is empty is refused" 1 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this' 'scripts/empty-test.sh'
rm "$tree/scripts/empty-test.sh"

script scripts/reasonless-test.sh '# check-not-run:'
list "a reason that is empty is refused" 1 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this' 'scripts/reasonless-test.sh'
rm "$tree/scripts/reasonless-test.sh"

script tests/other-test.sh '# check: lives in another folder'
list "a test in any folder of the repository is found" 0 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this
tests/other-test.sh lives in another folder'

script programs/server/hidden-test.sh -
list "a test that says nothing in any folder is refused" 1 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this
tests/other-test.sh lives in another folder' 'programs/server/hidden-test.sh'
rm "$tree/programs/server/hidden-test.sh"

script dist/built-test.sh -
script .git/hooks/x-test.sh -
list "build output and the git folder hold no tests" 0 \
    'scripts/a-test.sh a does that, then this
scripts/b-test.sh b does this
tests/other-test.sh lives in another folder'

# A test that is named in check.sh by hand would bring the conflicts back, and a test that is
# named there but says it is not run would be run against its own word.
if grep -Eq 'sh scripts/[a-z-]+-test\.sh' "$root/scripts/check.sh"; then
    printf 'FAIL check.sh names a test script itself\n'
    failed=$((failed + 1))
elif ! grep -q 'scripts/list-checked-tests.sh' "$root/scripts/check.sh"; then
    printf 'FAIL check.sh does not run the tests that list-checked-tests.sh lists\n'
    failed=$((failed + 1))
else
    printf 'ok   check.sh runs what list-checked-tests.sh lists and names no test itself\n'
fi

[ "$failed" -eq 0 ] || { printf '%s case(s) failed\n' "$failed"; exit 1; }
