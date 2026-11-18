#!/bin/sh
# Fails when the repository tracks something that must never be published: a compiled
# program, a very large file, or a file that names a private machine, account or place. A
# program built on a developer's machine carries the folder names of that machine; one was
# committed by mistake once, next to the code it was built from, and the ignore rules alone
# did not stop it. It runs on the host (make tracked-files, part of make check) and needs
# git, find, awk, xargs, tr and wc. Each check reads all the files in one pass, not one file at
# a time, so that it takes a fraction of a second.
set -eu

# Larger than any source file here.
limit=1048576

# Names that belong to the private systems of the people who work on this project. Each is
# put together from two pieces, so that this file does not hold the names it looks for.
# The copyright line in LICENSE names the company on purpose and is the one exception.
private_names=""
for pieces in blue:rival blue:xd hil:doer pho:enix new-:york castle-:rock; do
    private_names="$private_names ${pieces%%:*}${pieces#*:}"
done

# Bytes are compared as bytes, whatever the locale of the machine.
LC_ALL=C
export LC_ALL

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The files to read: the tracked ones that exist (a deleted file or a submodule folder is
# skipped), separated by zero bytes as xargs -0 wants them. A leading ./ keeps a name that
# starts with a dash from being taken for an option, and one with an equals sign for an awk
# assignment.
git ls-files | while read -r file; do
    if [ -f "$file" ]; then
        printf './%s\n' "$file"
    fi
done | tr '\n' '\0' > "$work/files"

# Runs a command with the files as its arguments, in as few runs as the length of a command
# line allows.
on_files() {
    xargs -0 -r "$@" < "$work/files"
}

# find takes the paths before the tests, and xargs puts the files last, so a shell reorders them.
# shellcheck disable=SC2016 # the dollar signs are for the inner shell
report_large_files() {
    large="$(on_files sh -c 'limit="$1"; shift; find -L "$@" -type f -size "+${limit}c"' sh "$limit")"
    [ -n "$large" ] || return 0
    printf '%s\n' "$large" | while read -r file; do
        size="$(wc -c < "$file")"
        echo "tracked file larger than 1 MiB: ${file#./} ($((size)) bytes)"
    done
}

# The first bytes say what a compiled program is: ELF (Linux, FreeBSD), Mach-O in its three
# forms (macOS), and MZ (Windows). The first line of a file holds them, and its first four
# bytes are all that is compared.
# shellcheck disable=SC2016 # the dollar sign is awk's own
report_programs() {
    on_files awk '
        FNR == 1 {
            head = substr($0, 1, 4)
            if (head == "\177ELF" || head == "\317\372\355\376" || head == "\316\372\355\376" ||
                head == "\312\376\272\276" || substr(head, 1, 2) == "MZ") {
                print "tracked file is a compiled program: " substr(FILENAME, 3)
            }
        }'
}

# -a reads a binary file as text, so a name inside a program is found too. git grep reads
# the tracked files and has no per-file cost; it exits 1 when nothing matches.
report_private_names() {
    set -- -F -a -i -l --no-color
    for name in $private_names; do
        set -- "$@" -e "$name"
    done
    status=0
    holders="$(git grep "$@" -- . ':(exclude)LICENSE')" || status=$?
    [ "$status" -le 1 ] || exit "$status"
    [ -n "$holders" ] || return 0
    printf '%s\n' "$holders" | while read -r file; do
        echo "tracked file holds a private name: $file"
    done
}

{
    report_large_files
    report_programs
    report_private_names
} > "$work/found"

if [ -s "$work/found" ]; then
    cat "$work/found"
    exit 1
fi
echo "tracked files: no compiled program, nothing over 1 MiB, no private name"
