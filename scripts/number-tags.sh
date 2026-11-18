#!/bin/sh
# Reads tag names on standard input, one per line, and prints the ones that are version tags of
# this repository, oldest first. A version tag is a plain positive whole number: 1, 2, 3. Every
# other tag (v0.4.20 from before the numbers) is not a version of this repository and is dropped.
# This is the one place that says what a version tag is; the next number, the previous tag and
# the check for a tagged commit all read it.
set -eu

# Numbers are ordered by their length first, then as text, so that the order does not depend on
# how large a number the tools can hold. grep exits 1 when nothing matches, which only means that
# there are no version tags, and the pipeline takes the status of its last command.
grep -E '^[1-9][0-9]*$' |
    awk '{ print length($0), $0 }' |
    sort -k1,1n -k2,2 |
    cut -d ' ' -f 2
