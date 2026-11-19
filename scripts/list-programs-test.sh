#!/bin/sh
# check: list-programs.sh: the programs of the repository as a JSON array for a workflow matrix
# Test of scripts/list-programs.sh (part of make check): the programs of a repository are the
# folders of programs/ that hold a program.conf, listed as a JSON array, and a program that
# program-conf.sh refuses stops the list. Runs on the host, on a fixture tree.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
failed=0

mkdir -p "$tree/scripts"
cp "$root/scripts/list-programs.sh" "$root/scripts/program-conf.sh" "$tree/scripts/"

# $1 the program folder, written with a complete program.conf.
program() {
    mkdir -p "$tree/programs/$1"
    printf 'name=n-%s\nprogram=p\nprograms=p\ndocs=README.md\nrelease_repo=example/%s\n' "$1" "$1" > "$tree/programs/$1/program.conf"
}

# $1 case name, $2 the exit status wanted, $3 the text the output must be (standard output) or,
# for a failure, contain (standard error).
list() {
    status=0
    got="$(sh "$tree/scripts/list-programs.sh" 2> "$tree/err")" || status=$?
    if [ "$status" -ne "$2" ]; then
        printf 'FAIL %s: status %s, wanted %s\n' "$1" "$status" "$2"
        failed=$((failed + 1))
    elif [ "$2" -eq 0 ] && [ "$got" != "$3" ]; then
        printf 'FAIL %s: wanted %s got %s\n' "$1" "$3" "$got"
        failed=$((failed + 1))
    elif [ "$2" -ne 0 ] && ! grep -q "$3" "$tree/err"; then
        printf 'FAIL %s: the error does not say "%s"\n' "$1" "$3"
        sed 's/^/     /' "$tree/err"
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

list "no program is an error" 1 "holds no program"

program server
list "one program" 0 '["server"]'

program client
mkdir "$tree/programs/notes"
list "every program with a program.conf, sorted by name; a folder without one is no program" 0 '["client","server"]'

printf 'program=x\n' > "$tree/programs/client/program.conf"
list "a program.conf that leaves a fact out stops the list" 1 'does not set name'

program client
program Bad_Name
list "a folder that is not a program name stops the list" 1 'is not a program name'

# The list is JSON that the matrix of a workflow reads; a hyphen and a digit are part of a name.
rm -rf "$tree/programs/Bad_Name"
program alpine-two
list "a name with a hyphen and a digit" 0 '["alpine-two","client","server"]'

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "list-programs checks done"
