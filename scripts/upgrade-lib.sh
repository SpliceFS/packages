# shellcheck shell=sh
# Sourced inside a system a package is installed in, by scripts/package-test-steps.sh (through
# scripts/system-state-lib.sh), with PROGRAM, VERSION, PACKAGE_DATE and PUBLISHED_VERSION (the
# program version of the package that is upgraded) in the environment. The scripts that source this
# file read these variables; this file reads none of them.
# shellcheck disable=SC2034
#
: "${VERSION:?VERSION is not set}"
: "${PACKAGE_DATE:?PACKAGE_DATE is not set}"
: "${PUBLISHED_VERSION:?PUBLISHED_VERSION is not set}"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh

# The package ships no configuration file, only empty folders for the administrator's files
# (programs/PROGRAM/config-folders), so the file an administrator would write there is the one the
# upgrade must leave alone. The package tests use the same name.
keptdir="$confdir/$(printf '%s\n' "$confsubdirs" | head -n 1)"
kept="$keptdir/$administrator_file"
marker="# upgrade-test marker: an upgrade must keep this line"
datafile="$datadir/upgrade-test-marker"

# Ends the caller unless the line and the file that write_markers wrote are still there. $1 names
# what was done to the system, for the message.
verify_markers_kept() {
    grep -qxF "$marker" "$kept" || fail "$1: the marker line is gone from $kept"
    [ -f "$datafile" ] || fail "$1: the marker file $datafile is gone"
}

# Writes the marker line and the marker file, the way an administrator and the running
# server would have, before the upgrade.
write_markers() {
    [ -d "$keptdir" ] || fail "$1 upgrade: $keptdir is missing after the install"
    printf '%s\n' "$marker" >> "$kept"
    mkdir -p "$datadir"
    printf 'written before the upgrade\n' > "$datafile"
}
