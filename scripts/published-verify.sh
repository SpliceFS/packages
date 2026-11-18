#!/bin/sh
# Proves that a package downloaded from the package site is the one the site publishes, the way a
# package manager does: the package by the SHA256 that the index of the site lists for it, and the
# index by its signature, checked against the public key of this repository (keys/splicefs.asc)
# only. A deb is listed by the Packages index, which the signed InRelease lists by its SHA256; an
# rpm by primary.xml.gz, which repomd.xml lists by its SHA256, and repomd.xml has a detached
# signature. An apk is proven by apk itself against the repository key when it installs one
# (scripts/upgrade-test-apk.sh), so there is nothing to check for it here. Anyone who could change
# a file on the site or on the way to the test must also change what it is proven by, and cannot
# sign the change.
# Usage: published-verify.sh SITE_PATH FILE
#   SITE_PATH  the path of the package on the site from the folder of the program, as
#              published_path in scripts/published-lib.sh makes it
#   FILE       the file that was downloaded from there
# Environment: PROGRAM; PACKAGE_SITE (https://packages.splicefs.org). Runs on the host, needs gpg
# and curl. Ends with a message and status 1 when the package or the index does not prove.
set -eu

site_path="${1:?usage: published-verify.sh SITE_PATH FILE}"
file="${2:?usage: published-verify.sh SITE_PATH FILE}"
cd "$(dirname "$0")/.."
# shellcheck source=program-conf.sh
. scripts/program-conf.sh
# shellcheck source=published-lib.sh
. scripts/published-lib.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

if command -v sha256sum >/dev/null 2>&1; then
    sums() { sha256sum -- "$1"; }
else
    sums() { shasum -a 256 -- "$1"; }
fi
# Prints the SHA256 of the file $1.
file_sha256() { sums "$1" | awk '{ print $1 }'; }

# Downloads the path $1 of the site into the file $2 of the work folder. A function in an || list
# has set -e off, and nothing here depends on it.
# shellcheck disable=SC2310
fetch() {
    fetch_site_file "$site_url/$1" "$work/$2" || fail "could not download $site_url/$1"
}

# Runs gpg with the keyring that holds the key of the project and no other, so that no other key
# can satisfy a check. The key is not imported into a home: that needs a gpg-agent, which a long
# path to the home (the temporary folder of macOS) makes gpg wait ten seconds for.
gpg_project() {
    GNUPGHOME="$work/home" gpg --batch --no-default-keyring --keyring "$work/home/project.gpg" "$@"
}

# Makes the keyring on the first use. want is the fingerprint of the primary key, which VALIDSIG
# field 12 names also when a subkey signed.
trust_project_key() {
    [ -z "${want:-}" ] || return 0
    command -v gpg >/dev/null 2>&1 || fail "gpg is not on the PATH"
    mkdir -m 700 "$work/home"
    GNUPGHOME="$work/home" gpg --batch --dearmor < keys/splicefs.asc > "$work/home/project.gpg" 2>/dev/null ||
        fail "could not read keys/splicefs.asc"
    want="$(gpg_project --with-colons --list-keys 2>/dev/null |
        awk -F: '$1 == "pub" { w = 1 } $1 == "fpr" && w { print $10; exit }')"
    [ -n "$want" ] || fail "no fingerprint in keys/splicefs.asc"
}

# Ends the script unless gpg accepted the signature (its status lines are in the file $1) and the
# key that made it is the key of the project. $2 is what was signed, for the message.
require_project_signature() {
    made_by="$(awk '$2 == "VALIDSIG" { print $12 }' "$1")"
    [ "$made_by" = "$want" ] || fail "$2 does not verify against keys/splicefs.asc"
}

# Writes the text of the clearsigned file $1 into the file $2 when the project signed it.
# shellcheck disable=SC2310
verify_clearsigned() {
    trust_project_key
    gpg_project --status-fd 1 --output "$2" --decrypt "$1" \
        >"$work/status" 2>/dev/null || fail "$(basename "$1") does not verify against keys/splicefs.asc"
    require_project_signature "$work/status" "$(basename "$1")"
}

# Ends the script unless the detached signature $1 is the project's signature of the file $2.
# shellcheck disable=SC2310
verify_detached() {
    trust_project_key
    gpg_project --status-fd 1 --verify "$1" "$2" \
        >"$work/status" 2>/dev/null || fail "$(basename "$2") does not verify against keys/splicefs.asc"
    require_project_signature "$work/status" "$(basename "$2")"
}

# Ends the script unless the file $1 has the SHA256 $2. $3 names what listed the sum, $4 the file.
require_sum() {
    actual="$(file_sha256 "$1")"
    [ "$actual" = "$2" ] || fail "$4 does not match the SHA256 that $3 lists for it (listed $2, got $actual)"
}

# Prints the SHA256 that the clearsigned Release text in the file $1 lists for the path $2, from the
# SHA256 section only: the lines of the section start with a space.
release_sum() {
    awk -v want="$2" '
        /^SHA256:/ { in_section = 1; next }
        /^[^ ]/ { in_section = 0 }
        in_section && $3 == want { print $1; exit }
    ' "$1"
}

# Prints the SHA256 that the Packages index in the file $1 lists for the package file whose path
# from the root of the repository is $2: the paragraph with that Filename.
packages_sum() {
    awk -v want="$2" '
        BEGIN { RS = ""; FS = "\n" }
        {
            listed = ""
            found = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "Filename: " want) found = 1
                if ($i ~ /^SHA256: /) listed = substr($i, 9)
            }
            if (found) { print listed; exit }
        }
    ' "$1"
}

verify_deb() {
    deb_file="$(basename "$site_path")"
    deb_arch="${deb_file%.deb}"
    deb_arch="${deb_arch##*_}"
    index_path="main/binary-$deb_arch/Packages"
    fetch apt/dists/stable/InRelease InRelease
    verify_clearsigned "$work/InRelease" "$work/Release"
    listed="$(release_sum "$work/Release" "$index_path")"
    [ -n "$listed" ] || fail "the signed InRelease lists no $index_path"
    fetch "apt/dists/stable/$index_path" Packages
    require_sum "$work/Packages" "$listed" "the signed Release" "the index $index_path"
    listed="$(packages_sum "$work/Packages" "${site_path#apt/}")"
    [ -n "$listed" ] || fail "the index $index_path lists no ${site_path#apt/}"
    require_sum "$file" "$listed" "the index of the site" "$deb_file"
}

# Prints the block of the XML text in the file $1 that holds the text $2, where a block ends with the
# tag $3. The text is put on one line first, so that it does not matter where the writer broke it.
xml_block() {
    tr '\n\t' '  ' < "$1" | sed "s|$3|&\\
|g" | grep -F -e "$2" | head -n 1
}

# Prints the sum of the SHA256 checksum element in the XML block on the standard input.
xml_sum() {
    sed -n 's|.*<checksum type="sha256"[^>]*>\([0-9a-f]*\)</checksum>.*|\1|p'
}

verify_rpm() {
    rpm_file="$(basename "$site_path")"
    repodata="$(dirname "$site_path")/repodata"
    fetch "$repodata/repomd.xml" repomd.xml
    fetch "$repodata/repomd.xml.asc" repomd.xml.asc
    verify_detached "$work/repomd.xml.asc" "$work/repomd.xml"
    primary="$(xml_block "$work/repomd.xml" '<data type="primary">' '</data>')"
    listed="$(printf '%s\n' "$primary" | xml_sum)"
    href="$(printf '%s\n' "$primary" | sed -n 's|.*<location href="\([^"]*\)".*|\1|p')"
    [ -n "$listed" ] && [ -n "$href" ] || fail "the signed repomd.xml lists no primary index with a SHA256"
    fetch "$(dirname "$site_path")/$href" primary.xml.gz
    require_sum "$work/primary.xml.gz" "$listed" "the signed repomd.xml" "the index $href"
    gzip -dc "$work/primary.xml.gz" > "$work/primary.xml" || fail "$href is not a gzip file"
    entry="$(xml_block "$work/primary.xml" "<location href=\"$rpm_file\"" '</package>')"
    listed="$(printf '%s\n' "$entry" | xml_sum)"
    [ -n "$listed" ] || fail "the index $href lists no $rpm_file with a SHA256"
    require_sum "$file" "$listed" "the index of the site" "$rpm_file"
}

case "$site_path" in
    *.deb) verify_deb ;;
    *.rpm) verify_rpm ;;
    *.apk) exit 0 ;;
    *) fail "$site_path is not a deb, an rpm or an apk" ;;
esac
echo "verified $(basename "$site_path") against the signed index of $site_url"
