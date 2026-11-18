#!/bin/sh
# Prints the FreeBSD releases of packaging/freebsd/releases as a JSON array on one line, for
# example ["14.5","15.1"]. The workflows read the matrix of their FreeBSD jobs from it, so a new
# release in the list needs no edit of a workflow. RELEASES_FILE names another list file.
# Usage: freebsd-releases.sh
set -eu

cd "$(dirname "$0")/.."
file="${RELEASES_FILE:-packaging/freebsd/releases}"
list=''
# Blank lines and comments are no release; any other line is one, named by its first word. A last
# line without a newline is read too: read reports it as a failure but sets the variable.
while read -r release _ || [ -n "$release" ]; do
    case "$release" in
        "" | "#"*) continue ;;
        *[!0-9.]*) echo "FAIL: $release in $file is not a release like 15.1" >&2; exit 1 ;;
        *) list="$list${list:+,}\"$release\"" ;;
    esac
done < "$file"
[ -n "$list" ] || { echo "FAIL: $file holds no release" >&2; exit 1; }
printf '[%s]\n' "$list"
