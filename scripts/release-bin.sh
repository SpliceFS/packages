#!/bin/sh
# Turns the release archives of a program into the folder the package scripts read as BIN: one
# folder <os>-<arch> for each archive, holding the programs named in program.conf. The archives
# are made by the program's own release (splicefs-<program>-<version>-<os>-<arch>.tar.gz, with
# SHA256SUMS and its signature SHA256SUMS.asc beside them). Nothing is unpacked before the
# signature is proven with the published key in keys/splicefs.asc and every archive is proven by
# SHA256SUMS. Runs on the host (the package-and-test workflow). Usage: release-bin.sh TAG
# ARCHIVE_DIR BIN_DIR, with PROGRAM in the environment. ARCHIVE_DIR holds the downloaded files
# and BIN_DIR is made; both are absolute, because the script works from the repository root.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
# shellcheck source=program-conf.sh
. scripts/program-conf.sh

[ "$#" -eq 3 ] || fail "usage: release-bin.sh TAG ARCHIVE_DIR BIN_DIR"
tag="$1"
archives="$2"
bin="$3"
# The version of the file names is the tag without the v.
version="${tag#v}"
# What program.conf sets is unknown to ShellCheck, which cannot follow it.
# shellcheck disable=SC2154
prefix="$name-$version-"

command -v gpg >/dev/null 2>&1 || fail "gpg is not on the PATH"
if command -v sha256sum >/dev/null 2>&1; then
    sums() { sha256sum -- "$@"; }
else
    sums() { shasum -a 256 -- "$@"; }
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
chmod 700 "$work"

# Ends the script unless SHA256SUMS was signed by the key the project publishes. The home holds
# only that key, so no other key can satisfy it. VALIDSIG field 11 of the status line is the
# fingerprint of the primary key, also when a subkey signed.
verify_signature() {
    [ -f "$archives/SHA256SUMS" ] || fail "$archives/SHA256SUMS is missing"
    [ -f "$archives/SHA256SUMS.asc" ] || fail "$archives/SHA256SUMS.asc is missing"
    mkdir "$work/home"
    chmod 700 "$work/home"
    GNUPGHOME="$work/home" gpg --batch --quiet --import keys/splicefs.asc >"$work/gpg.log" 2>&1 ||
        fail "could not import keys/splicefs.asc"
    want="$(GNUPGHOME="$work/home" gpg --batch --with-colons --list-keys 2>/dev/null |
        awk -F: '$1 == "pub" { w = 1 } $1 == "fpr" && w { print $10; exit }')"
    [ -n "$want" ] || fail "no fingerprint in keys/splicefs.asc"
    GNUPGHOME="$work/home" gpg --batch --status-fd 1 --verify "$archives/SHA256SUMS.asc" \
        "$archives/SHA256SUMS" >"$work/gpg.log" 2>/dev/null ||
        fail "SHA256SUMS.asc does not verify against keys/splicefs.asc"
    got="$(awk '$2 == "VALIDSIG" { print $12 }' "$work/gpg.log")"
    [ "$got" = "$want" ] || fail "SHA256SUMS.asc was not made by the key $want"
}

# Ends the script unless the archive in the file $1 is the one SHA256SUMS lists under its name.
verify_archive() {
    file="$(basename "$1")"
    listed="$(awk -v f="$file" '$2 == f { print $1 }' "$archives/SHA256SUMS")"
    [ -n "$listed" ] || fail "$file is not listed in SHA256SUMS"
    actual="$(sums "$1" | awk '{ print $1 }')"
    [ "$listed" = "$actual" ] || fail "$file does not match SHA256SUMS"
}

# Puts the programs of the verified archive $1 in the folder of its system under $bin.
unpack_archive() {
    file="$(basename "$1")"
    top="${file%.tar.gz}"
    system="${top#"$prefix"}"
    case "$system" in
        *[!a-z0-9-]*) fail "$file does not end in <os>-<arch>" ;;
        *) ;;
    esac
    rm -rf "${work:?}/unpacked"
    mkdir "$work/unpacked"
    tar -xzf "$1" -C "$work/unpacked"
    mkdir -p "$bin/$system"
    # The names are ours and hold no spaces, so the list is split on purpose. programs is set
    # by program.conf.
    # shellcheck disable=SC2154
    for built in $programs; do
        [ -f "$work/unpacked/$top/$built" ] || fail "$file holds no $built"
        cp "$work/unpacked/$top/$built" "$bin/$system/$built"
        chmod 755 "$bin/$system/$built"
    done
    echo "unpacked $file"
}

verify_signature
found=0
for archive in "$archives/$prefix"*.tar.gz; do
    # Without a match the pattern stays as it is, which is no file.
    [ -f "$archive" ] || continue
    found=$((found + 1))
    verify_archive "$archive"
    unpack_archive "$archive"
done
[ "$found" -gt 0 ] || fail "no archive of $name $version in $archives"
