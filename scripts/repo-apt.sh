#!/bin/sh
# Builds or updates the signed apt repository in OUTPUT_DIR/repo/apt from the .deb files in
# OUTPUT_DIR. It runs in the Go image (make repo), with the keys in /keys. The pool keeps
# every file already in it, so older versions stay installable. Every index file that Release
# lists is also stored under its hash (by-hash), so a client that is in the middle of an update
# still gets the file its Release names, which a Packages file that was replaced meanwhile
# would not be.
set -eu

out="${1:?usage: repo-apt.sh OUTPUT_DIR}"
repo="$out/repo/apt"
suite=stable
archs="amd64 arm64"

mkdir -p "$repo/pool"
set -- "$out"/*.deb
pooled="$(find "$repo/pool" -name '*.deb' | head -n 1)"
[ -e "$1" ] || [ -n "$pooled" ] || {
    echo "FAIL: no .deb files in $out; run make packages first" >&2
    exit 1
}

# A published version must never change, so a pool file with the same name and different
# content stops the run. Sorted input keeps the result the same on every run. ls prints
# nothing when no file matches; a glob would run the loop once with the pattern itself.
# shellcheck disable=SC2012
for deb in $(ls "$out"/*.deb 2>/dev/null | sort); do
    file="$(basename "$deb")"
    name="${file%%_*}"
    dest="$repo/pool/main/$(printf '%s' "$name" | cut -c1)/$name"
    if [ -f "$dest/$file" ]; then
        cmp -s "$deb" "$dest/$file" || {
            echo "FAIL: $file is already in the pool with different content" >&2
            exit 1
        }
        continue
    fi
    mkdir -p "$dest"
    cp "$deb" "$dest/$file"
done

# Paths in Packages are relative to the repository root, so the commands run from there.
cd "$repo"
rm -f "dists/$suite/Release" "dists/$suite/Release.gpg" "dists/$suite/InRelease"
# The folders hold the files of this build only: what the generation before it still needs is
# kept by the upload (scripts/publish-program.sh), which knows what is published. apt-ftparchive
# prunes old files by a count of its own, which would also drop files of this Release.
mkdir -p "dists/$suite"
find "dists/$suite" -type d -name by-hash -exec rm -rf {} +
for arch in $archs; do
    dir="dists/$suite/main/binary-$arch"
    mkdir -p "$dir"
    apt-ftparchive --arch "$arch" packages pool > "$dir/Packages"
    gzip -n -9 -c "$dir/Packages" > "$dir/Packages.gz"
done
# DoByHash writes the by-hash copies of every file Release lists (the hash types apt trusts, SHA256
# and SHA512, of which apt uses the strongest) and the line Acquire-By-Hash: yes into Release.
apt-ftparchive \
    -o APT::FTPArchive::DoByHash=true \
    -o APT::FTPArchive::Release::Origin=SpliceFS \
    -o APT::FTPArchive::Release::Label=SpliceFS \
    -o APT::FTPArchive::Release::Suite="$suite" \
    -o APT::FTPArchive::Release::Codename="$suite" \
    -o APT::FTPArchive::Release::Architectures="$archs" \
    -o APT::FTPArchive::Release::Components=main \
    release "dists/$suite" > "$out/Release.tmp"
mv "$out/Release.tmp" "dists/$suite/Release"

# The signing home lives in this container's temporary filesystem and dies with it. The
# secret file holds the signing subkey only, with no passphrase.
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import /keys/splicefs-openpgp-signing-subkey.asc 2>/dev/null
fpr="$(gpg --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10; exit}')"
gpg --batch --yes --pinentry-mode loopback --passphrase "" --default-key "$fpr" \
    --armor --detach-sign -o "dists/$suite/Release.gpg" "dists/$suite/Release"
gpg --batch --yes --pinentry-mode loopback --passphrase "" --default-key "$fpr" \
    --clearsign -o "dists/$suite/InRelease" "dists/$suite/Release"

count="$(find pool -name '*.deb' | wc -l | tr -d ' ')"
echo "built apt repository: $count packages"
