#!/bin/sh
# Decides whether the packaging of two versions differs, which is what makes an upgrade test
# worth running. It compares two package listings (see scripts/upgrade-lib.sh for the format)
# and ignores what the program's own source gives the package, which its version changes and
# which says nothing about the packaging: the programs named after the listings are left out
# altogether, and the documents named after "--" are compared without their content (that they
# are in the package, with their mode and owner, still counts: it is the packaging that installs
# them). Everything else in a listing counts: every file with its mode, owner and content, the
# install and remove scripts, and the declared dependencies and configuration files.
# Usage: upgrade-diff.sh OLD_LISTING NEW_LISTING [PROGRAM...] [-- DOCUMENT...]
# Exit status: 0 nothing differs, 1 something differs (the differences are printed, "-" for
# the old line and "+" for the new one), 2 wrong usage. Runs on the host, no Docker.
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: upgrade-diff.sh OLD_LISTING NEW_LISTING [PROGRAM...] [-- DOCUMENT...]" >&2
    exit 2
fi
for listing in "$1" "$2"; do
    [ -f "$listing" ] || { echo "upgrade-diff: $listing is not a file" >&2; exit 2; }
done
old="$1"
new="$2"
shift 2
# The names to leave out and the names of the documents, each with a space on both sides so only
# whole names match.
skip=" "
docs=" "
in_docs=no
for name in "$@"; do
    if [ "$name" = "--" ]; then
        in_docs=yes
    elif [ "$in_docs" = yes ]; then
        docs="$docs$name "
    else
        skip="$skip$name "
    fi
done

# A path line ends in the path, so the name of a program or document is the last part of that path.
# Only path lines are looked at: a dependency or a script line is never left out. The content sum
# is the fourth field of a file line.
keep() {
    LC_ALL=C awk -v skip="$skip" -v docs="$docs" '
        ($1 == "file" || $1 == "dir" || $1 == "link") {
            n = split($NF, part, "/")
            if (part[n] != "" && index(skip, " " part[n] " ") > 0) next
            if ($1 == "file" && part[n] != "" && index(docs, " " part[n] " ") > 0) $4 = "-"
        }
        { print }
    ' "$1" | LC_ALL=C sort
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
keep "$old" > "$work/old"
keep "$new" > "$work/new"

# Lines only in the old listing are what was removed or changed; lines only in the new one
# are what was added or changed. A changed file shows as one line of each.
removed="$(LC_ALL=C comm -23 "$work/old" "$work/new")"
added="$(LC_ALL=C comm -13 "$work/old" "$work/new")"
[ -n "$removed$added" ] || exit 0

{
    if [ -n "$removed" ]; then printf '%s\n' "$removed" | sed 's/^/  - /'; fi
    if [ -n "$added" ]; then printf '%s\n' "$added" | sed 's/^/  + /'; fi
} | awk -v max=40 '
    NR <= max { print }
    END { if (NR > max) printf "  ... and %d more lines\n", NR - max }
'
exit 1
