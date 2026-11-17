# shellcheck shell=sh
# The scripts that source this file read these variables; this file reads none of them.
# shellcheck disable=SC2034
# Sourced from the root of the repository by every script that needs to know what a program is,
# not only the ones that package it. Says which program PROGRAM is: it checks the name, reads
# programs/PROGRAM/program.conf and refuses one that leaves a fact out.
: "${PROGRAM:?PROGRAM is not set}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# PROGRAM names a folder of programs/, so it is a name and never a path.
case "$PROGRAM" in
    *[!a-z0-9-]*) fail "PROGRAM=$PROGRAM is not a program name" ;;
    *) ;;
esac
# The definitions of the program: what the packages hold, and program.conf, which says what the
# program is (name, program, programs and docs). This is the one place that says it.
defs="programs/$PROGRAM"
[ -f "$defs/program.conf" ] || fail "$defs/program.conf is missing: $PROGRAM is not a program of this repository"
# The folder is chosen by PROGRAM at run time, so there is no file for ShellCheck to follow.
# shellcheck source=/dev/null
. "$defs/program.conf"
for fact in name program programs docs; do
    eval "[ -n \"\${$fact:-}\" ]" || fail "$defs/program.conf does not set $fact"
done
