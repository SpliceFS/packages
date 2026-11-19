#!/bin/sh
# Prints the core dumps on the root filesystem of the system it runs in, one a line: the path, the
# pid, the program name and the command line of the process that dumped it, read from the
# NT_PRPSINFO note of the core. The lifecycle test runs it after every step, so a crash names its
# program and the step it happened in. The kernel writes a core where the host's core_pattern says,
# which in a container is the file core or core.PID in the folder the process was in, so files
# whose name starts with core are looked at, and only 64-bit ELF cores (amd64, arm64) are reported.
# Given paths, it reports those instead, each on a line, also one that is no core dump: the host's
# handler writes a core while the system runs on, so a core can be incomplete when it is looked at.
# Runs as root inside a container with only what a minimal system has: find, od, head and tail.
# CORE_ROOT, for its test, is a folder that stands in for the root; paths are as the system has them.
set -eu

top="${CORE_ROOT:-}"

# The unsigned little-endian number of $3 bytes at the offset $2 of the file $1; od reads in the
# byte order of the machine, which is that of the cores it can find.
number() { od -An -t "u$3" -j "$2" -N "$3" "$1" | tr -d ' \n'; }
# The text of at most $3 bytes at the offset $2 of the file $1, without its padding.
text() { tail -c +"$(($2 + 1))" "$1" | head -c "$3" | tr -d '\000'; }

# Prints the offset of the body of the NT_PRPSINFO note of the core $1, or nothing when the file
# is not a 64-bit ELF core or has no such note. Notes are 4-byte aligned: a name, then a body.
process_note() {
    size="$(wc -c <"$1")"
    [ "$size" -ge 64 ] || return 0
    magic="$(od -An -c -N 4 "$1" | tr -d ' ')"
    class="$(number "$1" 4 1)"
    kind="$(number "$1" 16 2)"
    [ "$magic" = '177ELF' ] || return 0
    [ "$class" = 2 ] && [ "$kind" = 4 ] || return 0
    phoff="$(number "$1" 32 8)"
    phentsize="$(number "$1" 54 2)"
    phnum="$(number "$1" 56 2)"
    i=0
    while [ "$i" -lt "$phnum" ]; do
        ph=$((phoff + i * phentsize))
        i=$((i + 1))
        type="$(number "$1" "$ph" 4)"
        [ "$type" = 4 ] || continue
        at="$(number "$1" $((ph + 8)) 8)"
        size="$(number "$1" $((ph + 32)) 8)"
        end=$((at + size))
        while [ $((at + 12)) -le "$end" ]; do
            namesz="$(number "$1" "$at" 4)"
            descsz="$(number "$1" $((at + 4)) 4)"
            type="$(number "$1" $((at + 8)) 4)"
            desc=$((at + 12 + (namesz + 3) / 4 * 4))
            if [ "$type" = 3 ]; then
                echo "$desc"
                return 0
            fi
            at=$((desc + (descsz + 3) / 4 * 4))
        done
    done
}

# Prints the line of the core dump at the path $1 of the system, or nothing when it is none.
core_line() {
    file="$top$1"
    [ -f "$file" ] || return 0
    desc="$(process_note "$file")"
    [ -n "$desc" ] || return 0
    pid="$(number "$file" $((desc + 24)) 4)"
    program="$(text "$file" $((desc + 40)) 16)"
    args="$(text "$file" $((desc + 56)) 80)"
    printf '%s pid %s program %s: %s\n' "$1" "$pid" "$program" "$args"
}

# Prints what the path $1 of the system is, when it is no core dump.
not_a_core() {
    if [ ! -f "$top$1" ]; then
        echo "$1: not a file"
        return 0
    fi
    start="$(od -An -c -N 4 "$top$1" | tr -s ' \n' ' ')"
    size="$(wc -c <"$top$1")"
    echo "$1: not a 64-bit ELF core with a process note: $((size)) bytes, starting${start% }"
}

if [ "$#" -gt 0 ]; then
    for path in "$@"; do
        line="$(core_line "$path")"
        if [ -n "$line" ]; then echo "$line"; else not_a_core "$path"; fi
    done
    exit 0
fi
find "$top/" -xdev -type f -name 'core*' -print | sed "s|^$top||" | LC_ALL=C sort | while IFS= read -r path; do
    core_line "$path"
done
