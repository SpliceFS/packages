#!/bin/sh
# check: published-verify.sh: a package of the site is proven by the signed index of the site
# Test of scripts/published-verify.sh: a package downloaded from the package site is proven by the
# checksum the site's own index lists for it, and the index by its signature, as a package manager
# does. Runs on the host, no Docker and no network (part of make check). It needs gpg, to make
# throwaway keys. A stand-in curl in a folder at the front of PATH serves a folder of the test as
# the site and refuses every other address. Every case changes one thing of a good site and says
# what the script must answer.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
# shellcheck source=short-tmp-lib.sh
. "$root/scripts/short-tmp-lib.sh"
# One home for both keys, because starting its agent is most of the time a key or a signature
# takes. The script that verifies needs no agent.
keys="$(short_tmp_dir)"
trap 'remove_short_tmp "$keys"; rm -rf "$work"' EXIT
failed=0

# A copy of the repository that holds what the script reads: the scripts, how a program is read,
# the published key, and a program of one package.
tree="$work/tree"
mkdir -p "$tree/programs/demo" "$tree/keys"
cp -R "$root/scripts" "$tree/"
printf 'name=splicefs-demo\nprogram=alphad\nprograms=alphad\ndocs=README.md\n' > "$tree/programs/demo/program.conf"

# Two keys: the one the project publishes and one that is not.
mkdir -m 700 "$keys/home"
new_key() {
    GNUPGHOME="$keys/home" gpg --batch --quiet --passphrase '' \
        --quick-generate-key "$1 <$1@example.invalid>" ed25519 sign never >/dev/null 2>&1
}
new_key project
new_key other
GNUPGHOME="$keys/home" gpg --batch --armor --export project > "$tree/keys/splicefs.asc"

# The stand-in curl serves the folder "site-root" of the test as https://site.example; the folder of
# the program is "demo" in it.
site_root="$work/site-root"
site="$site_root/demo"
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'STUB'
#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        https://*) url="$1" ;;
        *) ;;
    esac
    shift
done
case "$url" in
    https://site.example/*) path="${url#https://site.example/}" ;;
    *) exit 6 ;;
esac
[ -f "$SITE_DIR/$path" ] || exit 22
cp "$SITE_DIR/$path" "$out"
STUB
chmod 755 "$work/bin/curl"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'
}

deb_path=apt/pool/main/s/splicefs-demo/splicefs-demo_1.2.3-1_amd64.deb
rpm_path=rpm/x86_64/splicefs-demo-1.2.3-2.x86_64.rpm
index_dir=apt/dists/stable

# Writes the apt side of a good site: the package, the index that lists it, the Release that
# lists the index, and the signed InRelease, made with the key $1.
apt_site() {
    mkdir -p "$site/$(dirname "$deb_path")" "$site/$index_dir/main/binary-amd64"
    printf 'the deb\n' > "$site/$deb_path"
    printf 'Package: splicefs-other\nVersion: 9.9.9\nArchitecture: amd64\nFilename: pool/main/s/splicefs-other/splicefs-other_9.9.9_amd64.deb\nSHA256: 0000\n\n' \
        > "$site/$index_dir/main/binary-amd64/Packages"
    listed_sum="$(sha256 "$site/$deb_path")"
    printf 'Package: splicefs-demo\nVersion: 1.2.3-1\nArchitecture: amd64\nFilename: %s\nSHA256: %s\n\n' \
        "${deb_path#apt/}" "$listed_sum" >> "$site/$index_dir/main/binary-amd64/Packages"
    sign_release "$1"
}

# Writes the Release that lists the index as it is now, and the InRelease made from it with the
# key $1. The sums of other kinds come first, as apt-ftparchive writes them.
sign_release() {
    index="$site/$index_dir/main/binary-amd64/Packages"
    index_sum="$(sha256 "$index")"
    index_size="$(wc -c < "$index")"
    printf 'Suite: stable\nMD5Sum:\n 00 1 main/binary-amd64/Packages\nSHA256:\n %s %s main/binary-amd64/Packages\n' \
        "$index_sum" "${index_size##* }" > "$work/Release"
    rm -f "$site/$index_dir/InRelease"
    GNUPGHOME="$keys/home" gpg --batch --quiet --local-user "$1" --clearsign --output "$site/$index_dir/InRelease" "$work/Release"
}

# Writes the rpm side of a good site: the package, the index of the packages (primary.xml.gz, as
# createrepo_c writes it, one element to a line), repomd.xml that lists it, and the detached
# signature of repomd.xml made with the key $1.
rpm_site() {
    mkdir -p "$site/rpm/x86_64/repodata"
    printf 'the rpm\n' > "$site/$rpm_path"
    primary="$work/primary.xml"
    rpm_sum="$(sha256 "$site/$rpm_path")"
    {
        printf '<metadata>\n<package type="rpm">\n  <name>splicefs-other</name>\n'
        printf '  <checksum type="sha256" pkgid="YES">0000</checksum>\n  <location href="splicefs-other-9.9.9-1.x86_64.rpm"/>\n</package>\n'
        printf '<package type="rpm">\n  <name>splicefs-demo</name>\n'
        printf '  <checksum type="sha256" pkgid="YES">%s</checksum>\n' "$rpm_sum"
        printf '  <location href="%s"/>\n</package>\n</metadata>\n' "$(basename "$rpm_path")"
    } > "$primary"
    gzip -n -c "$primary" > "$site/rpm/x86_64/repodata/primary.xml.gz"
    sign_repomd "$1"
}

# Writes repomd.xml for the primary.xml.gz as it is now, and its signature made with the key $1.
sign_repomd() {
    repodata="$site/rpm/x86_64/repodata"
    primary_sum="$(sha256 "$repodata/primary.xml.gz")"
    {
        printf '<repomd>\n<data type="filelists">\n  <checksum type="sha256">0000</checksum>\n  <location href="repodata/filelists.xml.gz"/>\n</data>\n'
        printf '<data type="primary">\n  <checksum type="sha256">%s</checksum>\n' "$primary_sum"
        printf '  <location href="repodata/primary.xml.gz"/>\n</data>\n</repomd>\n'
    } > "$repodata/repomd.xml"
    rm -f "$repodata/repomd.xml.asc"
    GNUPGHOME="$keys/home" gpg --batch --quiet --local-user "$1" --armor --detach-sign --output "$repodata/repomd.xml.asc" "$repodata/repomd.xml"
}

# A signature takes a gpg-agent round trip (about half a second), so the good site is made and signed
# once, with the signatures of the other key made once too, and every case starts from a copy.
apt_site project
rpm_site project
cp -R "$site_root" "$work/good"
sign_release other
sign_repomd other
cp "$site/$index_dir/InRelease" "$work/other-InRelease"
cp "$site/rpm/x86_64/repodata/repomd.xml.asc" "$work/other-repomd.xml.asc"

fresh_site() {
    rm -rf "$site_root"
    cp -R "$work/good" "$site_root"
}

# $1 case name, $2 site path of the package, $3 the file that was downloaded, $4 the words the
# script must print (empty: it must succeed).
verify() {
    status=0
    got="$(cd "$tree" && SITE_DIR="$site_root" PATH="$work/bin:$PATH" PACKAGE_SITE=https://site.example PROGRAM=demo \
        sh scripts/published-verify.sh "$2" "$3" 2>&1)" || status=$?
    if [ -z "$4" ] && [ "$status" -eq 0 ]; then
        printf 'ok   %s\n' "$1"
    elif [ -n "$4" ] && [ "$status" -ne 0 ] && printf '%s' "$got" | grep -qF -e "$4"; then
        printf 'ok   %s: refused, "%s"\n' "$1" "$4"
    else
        printf 'FAIL %s: status %s, want "%s": %s\n' "$1" "$status" "$4" "$got"
        failed=$((failed + 1))
    fi
}

printf 'tampered\n' > "$work/tampered"

fresh_site
verify "deb: the package the index lists" "$deb_path" "$site/$deb_path" ""
verify "deb: a package that is not the one the index lists" "$deb_path" "$work/tampered" "does not match the SHA256 that the index of the site lists"
verify "deb: a package the index does not list" "apt/pool/main/s/splicefs-demo/splicefs-demo_1.2.4_amd64.deb" "$site/$deb_path" "lists no"

tampered_sum="$(sha256 "$work/tampered")"
fresh_site
printf 'Package: splicefs-demo\nVersion: 1.2.3-1\nArchitecture: amd64\nFilename: %s\nSHA256: %s\n\n' \
    "${deb_path#apt/}" "$tampered_sum" > "$site/$index_dir/main/binary-amd64/Packages"
verify "deb: an index that was changed after it was signed" "$deb_path" "$work/tampered" "does not match the SHA256 that the signed Release lists"

fresh_site
cp "$work/other-InRelease" "$site/$index_dir/InRelease"
verify "deb: an index signed with another key" "$deb_path" "$site/$deb_path" "does not verify against keys/splicefs.asc"

fresh_site
sed 's/^Suite: stable/Suite: changed/' "$site/$index_dir/InRelease" > "$work/InRelease"
cp "$work/InRelease" "$site/$index_dir/InRelease"
verify "deb: a signed Release that was changed" "$deb_path" "$site/$deb_path" "does not verify against keys/splicefs.asc"

fresh_site
cp "$work/Release" "$site/$index_dir/InRelease"
verify "deb: a Release that is not signed" "$deb_path" "$site/$deb_path" "does not verify against keys/splicefs.asc"

fresh_site
rm "$site/$index_dir/InRelease"
verify "deb: a site that has no InRelease" "$deb_path" "$site/$deb_path" "could not download"

fresh_site
verify "rpm: the package the index lists" "$rpm_path" "$site/$rpm_path" ""
verify "rpm: a package that is not the one the index lists" "$rpm_path" "$work/tampered" "does not match the SHA256 that the index of the site lists"
verify "rpm: a package the index does not list" "rpm/x86_64/splicefs-demo-1.2.4-1.x86_64.rpm" "$site/$rpm_path" "lists no"

fresh_site
printf '<metadata>\n<package type="rpm">\n  <checksum type="sha256" pkgid="YES">%s</checksum>\n  <location href="%s"/>\n</package>\n</metadata>\n' \
    "$tampered_sum" "$(basename "$rpm_path")" | gzip -n -c > "$site/rpm/x86_64/repodata/primary.xml.gz"
verify "rpm: an index of packages that was changed after it was signed" "$rpm_path" "$work/tampered" "does not match the SHA256 that the signed repomd.xml lists"

fresh_site
cp "$work/other-repomd.xml.asc" "$site/rpm/x86_64/repodata/repomd.xml.asc"
verify "rpm: repomd.xml signed with another key" "$rpm_path" "$site/$rpm_path" "does not verify against keys/splicefs.asc"

fresh_site
sed 's/filelists/changed/' "$site/rpm/x86_64/repodata/repomd.xml" > "$work/repomd.xml"
cp "$work/repomd.xml" "$site/rpm/x86_64/repodata/repomd.xml"
verify "rpm: a repomd.xml that was changed after it was signed" "$rpm_path" "$site/$rpm_path" "does not verify against keys/splicefs.asc"

fresh_site
rm "$site/rpm/x86_64/repodata/repomd.xml.asc"
verify "rpm: a site that has no signature of repomd.xml" "$rpm_path" "$site/$rpm_path" "could not download"

fresh_site
# apk proves its own packages against the repository key when it installs one
# (scripts/upgrade-test-apk.sh), so there is nothing for this script to prove.
verify "apk: left to apk" "alpine/x86_64/splicefs-demo-1.2.3-r1.apk" "$site/$deb_path" ""
verify "a file of no format we publish" "apt/pool/main/s/splicefs-demo/notes.txt" "$site/$deb_path" "is not a deb, an rpm or an apk"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "published-verify: all cases as expected"
