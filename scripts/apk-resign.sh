#!/bin/sh
# Signs the Alpine packages in OUTPUT_DIR/alpine/<cpu> again, in place, with the repository key in
# /keys, and changes nothing else in them. It runs in the apk-build image, like repo-apk.sh, which
# then builds the repository from them. Only its own test (scripts/apk-resign-test.sh) runs it now.
# It is for one repository that serves packages made with other keys: the new ones by the builds
# of each program, the published release by the release key, and apk finds the key to check a
# package by the name inside it.
#
# An Alpine package is three gzip streams one after the other: the signature, the control part
# and the data. The signature covers the control stream only. abuild makes a package by signing
# control.tar.gz with abuild-sign, which puts the signature stream in front of it, so this does
# the same: it cuts the old signature stream off, lets abuild-sign sign the control stream and
# puts the data stream behind it, byte for byte as it was.
set -eu

out="${1:?usage: apk-resign.sh OUTPUT_DIR}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The private key is copied into this container's temporary filesystem, where abuild-sign can
# read it whatever the mode on the host is. The public name comes from the file name.
keydir="$(mktemp -d)"
work="$(mktemp -d)"
trap 'rm -rf "$keydir" "$work"' EXIT
cp /keys/splicefs.rsa /keys/splicefs.rsa.pub "$keydir/"
chmod 600 "$keydir/splicefs.rsa"

# Prints the byte offset of every place in the file $1 where the three bytes that start a gzip
# stream are, one per line. Some are inside compressed data by chance; stream_end sorts them out.
gzip_marks() {
    xxd -p "$1" | tr -d '\n' | awk '{
        base = 0
        while ((i = index(substr($0, base + 1), "1f8b08")) > 0) {
            at = base + i - 1
            if (at % 2 == 0) print at / 2
            base = base + i
        }
    }'
}

# Prints the byte offset where the gzip stream that starts at byte $2 of the file $1 ends: the
# first place where the bytes from there to that place are a whole stream. gzip -t checks the
# checksum at the end of a stream, so a stream that is cut short never passes. The end of the file
# is the last place tried.
stream_end() {
    size="$(wc -c < "$1")"
    for mark in $(gzip_marks "$1") "$size"; do
        [ "$mark" -gt "$2" ] || continue
        if head -c "$mark" "$1" | tail -c +"$(($2 + 1))" | gzip -t 2>/dev/null; then
            echo "$mark"
            return
        fi
    done
    fail "$1 has a gzip stream that does not end"
}

resign() {
    pkg="$1"
    [ -f "$pkg" ] || fail "no Alpine package in $out/alpine"
    size="$(wc -c < "$pkg")"
    sig_end="$(stream_end "$pkg" 0)"
    control_end="$(stream_end "$pkg" "$sig_end")"
    data_end="$(stream_end "$pkg" "$control_end")"
    [ "$data_end" = "$size" ] ||
        fail "$pkg is not an Alpine package: it must have a signature, a control and a data stream"
    # The signature file is the first entry of the first stream, after the pax header that names it.
    head -c "$sig_end" "$pkg" | gzip -dc | head -c 512 | grep -aq '\.SIGN\.' ||
        fail "$pkg is not a signed Alpine package: its first stream is not a signature"
    tail -c +"$((sig_end + 1))" "$pkg" | head -c "$((control_end - sig_end))" > "$work/control.tar.gz"
    abuild-sign -q -k "$keydir/splicefs.rsa" -p "$keydir/splicefs.rsa.pub" "$work/control.tar.gz"
    { cat "$work/control.tar.gz"; tail -c +"$((control_end + 1))" "$pkg"; } > "$work/signed.apk"
    chmod 644 "$work/signed.apk"
    mv "$work/signed.apk" "$pkg"
    echo "signed again: $pkg"
}

for apk in "$out"/alpine/*/*.apk; do
    resign "$apk"
done
