#!/bin/sh
# check: release-bin.sh: release archives proven and unpacked to the layout of dist/bin
# Test of scripts/release-bin.sh: the release archives of a program become the dist/bin layout
# the package scripts read, and only after the signature and the checksums are proven. Runs on
# the host, no Docker and no network (part of make check). It needs gpg, to make throwaway keys.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
# shellcheck source=short-tmp-lib.sh
. "$root/scripts/short-tmp-lib.sh"
keys="$(short_tmp_dir)"
trap 'remove_short_tmp "$keys"; rm -rf "$work"' EXIT
# Where the script unpacks to.
bin="$work/bin"
failed=0

# A copy of the repository that holds what the script reads: the script itself, how a program is
# read, the published key, and a program of two executables.
tree="$work/tree"
mkdir -p "$tree/scripts" "$tree/programs/demo" "$tree/keys"
cp "$root/scripts/release-bin.sh" "$root/scripts/program-conf.sh" "$tree/scripts/"
printf 'name=splicefs-demo\nprogram=alphad\nprograms="alphad alphactl"\ndocs=README.md\n' > "$tree/programs/demo/program.conf"

# Two keys: the one the project publishes and one that is not.
new_key() {
    mkdir -m 700 "$keys/home-$1"
    GNUPGHOME="$keys/home-$1" gpg --batch --quiet --passphrase '' \
        --quick-generate-key "$1 <$1@example.invalid>" ed25519 sign never >/dev/null 2>&1
}
new_key project
new_key other
GNUPGHOME="$keys/home-project" gpg --batch --armor --export project > "$tree/keys/splicefs.asc"

# Makes a release in the folder $1 the way the release makes it: the archives of linux-amd64 and
# linux-arm64 of version 1.2.3, each with a folder of its own holding the programs, the license
# and the README, SHA256SUMS and its signature made with the key $2.
release() {
    mkdir -p "$1" "$work/stage"
    for system in linux-amd64 linux-arm64; do
        top="splicefs-demo-1.2.3-$system"
        rm -rf "$work/stage"
        mkdir -p "$work/stage/$top"
        printf 'alphad for %s\n' "$system" > "$work/stage/$top/alphad"
        printf 'alphactl for %s\n' "$system" > "$work/stage/$top/alphactl"
        printf 'license\n' > "$work/stage/$top/LICENSE"
        printf 'readme\n' > "$work/stage/$top/README.txt"
        chmod 755 "$work/stage/$top/alphad" "$work/stage/$top/alphactl"
        tar -czf "$1/$top.tar.gz" -C "$work/stage" "$top"
    done
    sign "$1" "$2"
}

if command -v sha256sum >/dev/null 2>&1; then
    sums() { sha256sum -- "$@"; }
else
    sums() { shasum -a 256 -- "$@"; }
fi

# Writes SHA256SUMS of the archives in the folder $1 and signs it with the key $2.
sign() {
    (cd "$1" && sums ./*.tar.gz | sed 's|  \./|  |' > SHA256SUMS)
    rm -f "$1/SHA256SUMS.asc"
    GNUPGHOME="$keys/home-$2" gpg --batch --quiet --armor --detach-sign \
        --output "$1/SHA256SUMS.asc" "$1/SHA256SUMS"
}

# Runs the script on the release folder $1 for the tag $2, unpacking into the folder $3.
unpack() {
    (cd "$work" && PROGRAM=demo sh "$tree/scripts/release-bin.sh" "$2" "$1" "$3" 2>&1)
}

# $1 case name, $2 release folder, $3 tag, $4 text the refusal must contain.
refuses() {
    rm -rf "${bin:?}"
    # The status of unpack is the answer here, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if got="$(unpack "$2" "$3" "$bin")"; then
        printf 'FAIL %s was accepted\n' "$1"
        failed=$((failed + 1))
    elif printf '%s' "$got" | grep -qF -- "$4"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s was refused with the wrong message: %s\n' "$1" "$got"
        failed=$((failed + 1))
    fi
}

# $1 case name, $2 what was wanted, $3 what there is.
expect() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

release "$work/good" project
# The status of unpack is the answer here, so set -e being off inside it changes nothing.
# shellcheck disable=SC2310
if got="$(unpack "$work/good" v1.2.3 "$bin")"; then
    printf 'ok   a good release is unpacked\n'
else
    printf 'FAIL a good release was refused: %s\n' "$got"
    failed=$((failed + 1))
fi

# Prints the files of the folders of $1, written folder/file and separated by spaces.
files_of() {
    out=""
    for d in "$1"/*; do
        for f in "$d"/*; do out="$out${out:+ }${d##*/}/${f##*/}"; done
    done
    echo "$out"
}
got="$(files_of "$bin")"
expect "one folder for each system, holding the programs of program.conf and nothing else" \
    "linux-amd64/alphactl linux-amd64/alphad linux-arm64/alphactl linux-arm64/alphad" "$got"
read -r got < "$bin/linux-arm64/alphad"
expect "the programs are the built files" "alphad for linux-arm64" "$got"
runs=no
if [ -x "$bin/linux-arm64/alphad" ]; then runs=yes; fi
expect "the programs can run" yes "$runs"

# A stray archive of another version in the folder is not a system of this one.
cp "$work/good/splicefs-demo-1.2.3-linux-amd64.tar.gz" "$work/good/splicefs-demo-1.2.2-linux-amd64.tar.gz"
sign "$work/good" project
rm -rf "${bin:?}"
unpack "$work/good" v1.2.3 "$bin" >/dev/null
systems=""
for d in "$bin"/*; do systems="$systems${systems:+ }${d##*/}"; done
expect "an archive of another version is left out" "linux-amd64 linux-arm64" "$systems"

release "$work/forged" other
refuses "a SHA256SUMS signed by another key" "$work/forged" v1.2.3 "does not verify"

release "$work/edited" project
printf '0000  splicefs-demo-1.2.3-linux-arm64.tar.gz\n' >> "$work/edited/SHA256SUMS"
refuses "a SHA256SUMS changed after it was signed" "$work/edited" v1.2.3 "does not verify"

release "$work/swapped" project
printf 'not the archive\n' > "$work/swapped/splicefs-demo-1.2.3-linux-arm64.tar.gz"
refuses "an archive that is not the one that was signed" "$work/swapped" v1.2.3 "does not match SHA256SUMS"

release "$work/unlisted" project
cp "$work/unlisted/splicefs-demo-1.2.3-linux-arm64.tar.gz" "$work/unlisted/splicefs-demo-1.2.3-linux-riscv64.tar.gz"
refuses "an archive SHA256SUMS does not list" "$work/unlisted" v1.2.3 "is not listed in SHA256SUMS"

release "$work/unsigned" project
rm "$work/unsigned/SHA256SUMS.asc"
refuses "a release without its signature" "$work/unsigned" v1.2.3 "SHA256SUMS.asc"

release "$work/other-version" project
refuses "a tag no archive is made for" "$work/other-version" v9.9.9 "no archive of splicefs-demo 9.9.9"

release "$work/short" project
rm -rf "$work/stage"
mkdir -p "$work/stage/splicefs-demo-1.2.3-linux-amd64"
printf 'alphad\n' > "$work/stage/splicefs-demo-1.2.3-linux-amd64/alphad"
tar -czf "$work/short/splicefs-demo-1.2.3-linux-amd64.tar.gz" -C "$work/stage" splicefs-demo-1.2.3-linux-amd64
sign "$work/short" project
refuses "an archive that lacks a program of program.conf" "$work/short" v1.2.3 "holds no alphactl"

if [ "$failed" -ne 0 ]; then
    echo "$failed release-bin case(s) failed"
    exit 1
fi
echo "release-bin: all cases as expected"
