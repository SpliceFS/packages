#!/bin/sh
# Prints the programs of this repository as a JSON array on one line, for example
# ["client","server"]: the folders of programs/ that hold a program.conf. The publish workflow
# starts one publish for each of them, so a new program needs no edit of a workflow. A program
# that scripts/program-conf.sh refuses (a name that is not a name, a fact left out) stops the
# list, so that it is said once, before anything is built.
# Usage: list-programs.sh
set -eu

cd "$(dirname "$0")/.."
list=''
for conf in programs/*/program.conf; do
    [ -f "$conf" ] || continue
    PROGRAM="$(basename "$(dirname "$conf")")"
    # A subshell, so that the facts of one program are never left for the next.
    # shellcheck source=program-conf.sh
    (. scripts/program-conf.sh)
    list="$list${list:+,}\"$PROGRAM\""
done
[ -n "$list" ] || { echo "FAIL: programs/ holds no program" >&2; exit 1; }
printf '[%s]\n' "$list"
