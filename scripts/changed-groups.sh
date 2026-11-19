#!/bin/sh
# Prints the test groups that the changed paths read from standard input need, one path a line,
# as a JSON array on one line, for example ["deb","install"]: for each path the groups of
# the first line of .github/test-groups that matches it, and every group for a path that no line
# matches, so that a new file is tested in full until it is named there. The CI of a pull request
# runs a job only when its group is in the array. "all" prints every group, for the runs that
# test everything.
# Usage: git diff --name-only BASE HEAD | changed-groups.sh
#        changed-groups.sh all
set -eu

cd "$(dirname "$0")/.."
# The patterns are matched against paths, never expanded against the files of this folder.
set -f
rules="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' .github/test-groups)"

every_group() {
    printf '%s\n' "$rules" | awk '{ for (i = 2; i <= NF; i++) print $i }'
}

# $1 a path. Prints the groups of the first rule that matches it, or every group.
groups_of() {
    while read -r pattern groups; do
        # shellcheck disable=SC2254 # the pattern of the rule is a pattern on purpose
        case $1 in
            $pattern)
                printf '%s\n' "$groups"
                return 0
                ;;
            *) ;;
        esac
    done <<EOF
$rules
EOF
    every_group
}

changed_groups() {
    while IFS= read -r path || [ -n "$path" ]; do
        groups_of "$path"
    done
}

json_array() {
    awk '{ for (i = 1; i <= NF; i++) print $i }' | LC_ALL=C sort -u |
        awk 'BEGIN { printf "[" } { printf "%s\"%s\"", (NR > 1 ? "," : ""), $0 } END { print "]" }'
}

case "${1:-}" in
    all) every_group | json_array ;;
    '') changed_groups | json_array ;;
    *)
        echo "usage: changed-groups.sh [all], with the changed paths on standard input" >&2
        exit 1
        ;;
esac
