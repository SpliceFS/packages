#!/bin/sh
# Test of the way the Makefile describes itself (part of make check): make help lists every
# target that has a comment above it, and every target the README names as "make TARGET" is
# defined in the Makefile. The real files are checked, and copies with one fault each prove that
# every fault is found. Runs on the host, no Docker.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# Prints the targets of the Makefile $1 that have a comment above them. A .PHONY line between the
# comment and the target does not separate them; any other line does. A line with an assignment
# after the colon is a target-specific variable, not a target.
commented_targets() {
    awk '
        /^#/ { commented = 1; next }
        /^\.PHONY:/ { next }
        {
            line = $0
            sub(/ ## .*/, "", line)
            if (commented && line ~ /^[a-zA-Z0-9_-]+:/ && line !~ /=/) {
                sub(/:.*/, "", line)
                print line
            }
            commented = 0
        }
    ' "$1"
}

# Prints the targets the file $1 names as "make TARGET": in backquotes or at the start of a line.
named_targets() {
    { grep -Eo '(^|`)make [a-z][a-z0-9_-]*' "$1" || true; } | sed 's/.*make //' | sort -u
}

# Prints one line for each problem of the folder $1, which holds a Makefile and a README.md.
problems() {
    dir="$1"
    make --no-print-directory -s -C "$dir" help > "$work/help"
    awk '{ print $1 }' "$work/help" > "$work/listed"
    for target in $(named_targets "$dir/README.md"); do
        grep -Eq "^$target:" "$dir/Makefile" ||
            echo "README names make $target, which the Makefile does not define"
    done
    for target in $(commented_targets "$dir/Makefile"); do
        grep -qx "$target" "$work/listed" ||
            echo "make help does not list $target, which has a comment"
    done
}

# $1 case name, $2 folder, $3 the problems wanted (empty for none).
check() {
    problems "$2" > "$work/found"
    got="$(cat "$work/found")"
    if [ "$got" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: wanted "%s", got "%s"\n' "$1" "$3" "$got"
        failed=$((failed + 1))
    fi
}

# Makes the folder $1 as a copy of the real Makefile and README, and appends $2 to the Makefile.
copy_with() {
    mkdir "$work/$1"
    cp "$root/Makefile" "$root/README.md" "$work/$1/"
    printf '%s\n' "$2" >> "$work/$1/Makefile"
}

check "the real Makefile and README agree with make help" "$root" ""

mkdir "$work/readme"
cp "$root/Makefile" "$work/readme/"
{ cat "$root/README.md"; echo 'make no-such-target   # a line of a code block'; } > "$work/readme/README.md"
check "a README that names a target the Makefile lacks" "$work/readme" \
    "README names make no-such-target, which the Makefile does not define"

copy_with bare '
# Does a thing.
bare-target:
	true'
check "a target with a comment and no description for make help" "$work/bare" \
    "make help does not list bare-target, which has a comment"

copy_with phony '
# Does a thing.
.PHONY: phony-target
phony-target:
	true'
check "a .PHONY line does not separate the comment from its target" "$work/phony" \
    "make help does not list phony-target, which has a comment"

copy_with described '
# Does a thing.
described-target: ## Does a thing
	true'
check "a target with a description is listed" "$work/described" ""

copy_with plain '
plain-target:
	true'
check "a target without a comment is not required in make help" "$work/plain" ""

mkdir "$work/fstab"
sed 's/^\(fstab-test: .*\) ## .*/\1/' "$root/Makefile" > "$work/fstab/Makefile"
cp "$root/README.md" "$work/fstab/"
check "a real target that loses its description" "$work/fstab" \
    "make help does not list fstab-test, which has a comment"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "make help: all cases as expected"
