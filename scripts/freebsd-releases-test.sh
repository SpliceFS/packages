#!/bin/sh
# Test of scripts/freebsd-releases.sh (part of make check): the FreeBSD releases of a list file
# come out as a JSON array on one line, in file order, with comments and blank lines left out,
# and a list that holds no release or a name that is not a release stops. Runs on the host, on
# fixture files.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# $1 case name, $2 the exit status wanted, $3 the list file content (printf format), $4 the text
# the output must be (standard output) or, for a failure, contain (standard error).
releases() {
    printf '%b' "$3" > "$work/releases"
    status=0
    got="$(RELEASES_FILE="$work/releases" sh "$root/scripts/freebsd-releases.sh" 2> "$work/err")" || status=$?
    if [ "$status" -ne "$2" ]; then
        printf 'FAIL %s: status %s, wanted %s\n' "$1" "$status" "$2"
        failed=$((failed + 1))
    elif [ "$2" -eq 0 ] && [ "$got" != "$4" ]; then
        printf 'FAIL %s: wanted %s got %s\n' "$1" "$4" "$got"
        failed=$((failed + 1))
    elif [ "$2" -ne 0 ] && ! grep -q "$4" "$work/err"; then
        printf 'FAIL %s: the error does not say "%s"\n' "$1" "$4"
        sed 's/^/     /' "$work/err"
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

releases "one release" 0 '15.1\n' '["15.1"]'
releases "every release in file order" 0 '14.5\n15.1\n' '["14.5","15.1"]'
releases "comments and blank lines are no release" 0 '# The releases.\n\n14.5\n  \n# 14.4\n15.1\n' '["14.5","15.1"]'
releases "text after the release on a line is not part of it" 0 '14.5 extra\n' '["14.5"]'
releases "a last line without a newline" 0 '14.5\n15.1' '["14.5","15.1"]'
releases "no release is an error" 1 '# nothing\n\n' 'holds no release'
releases "a name that is not a release is an error" 1 '14.5\nmain\n' 'is not a release'

# The real list is JSON that the matrix of a workflow reads.
got="$(sh "$root/scripts/freebsd-releases.sh")"
case "$got" in
    '["'*'"]') printf 'ok   the real list of packaging/freebsd/releases\n' ;;
    *)
        printf 'FAIL the real list: got %s\n' "$got"
        failed=$((failed + 1))
        ;;
esac

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "freebsd-releases checks done"
