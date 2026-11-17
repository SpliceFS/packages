#!/bin/sh
# Writes what scripts/revision-decide.sh compares, for this machine's CPU type: the package
# listings (scripts/upgrade-lib.sh) of the newest published revision of a release, downloaded
# from the package site, and of the packages in dist/PROGRAM that make packages built from the
# same release as the next revision. The packages are read inside the container of the first
# system of each format in packaging/test-systems, which has the tools of the format.
# Usage: revision-listings.sh PROGRAM TAG LISTINGS_DIR
# Environment: PACKAGE_SITE (https://packages.splicefs.org). Needs Docker and the network.
set -eu

PROGRAM="${1:?usage: revision-listings.sh PROGRAM TAG LISTINGS_DIR}"
TAG="${2:?usage: revision-listings.sh PROGRAM TAG LISTINGS_DIR}"
OUT="${3:?usage: revision-listings.sh PROGRAM TAG LISTINGS_DIR}"
export PROGRAM
cd "$(dirname "$0")/.."
root="$(pwd)"
site="${PACKAGE_SITE:-https://packages.splicefs.org}/$PROGRAM"

# The revision these packages were built as, and the names of the published ones before it.
next="$(sh scripts/next-revision.sh "$PROGRAM" "$TAG")"
[ "$next" -gt 0 ] || { echo "$TAG of $PROGRAM is not published, so there is nothing to compare with" >&2; exit 1; }
PACKAGE_DATE="$(date +%Y%m%d)"
export VERSION="$TAG" REVISION="$next" PACKAGE_DATE
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
names="$(package_versions "$TAG" "$((next - 1))" "$PACKAGE_DATE")"
read -r old_debver old_rpmver old_rpmrel old_apkver old_apkrel _ <<LIST
$names
LIST

mkdir -p "$OUT/files"
built="$root/dist/$PROGRAM"
out="$(cd "$OUT" && pwd)"
# Arguments: format, the path of the published package on the site, the file name, and the path
# of the new package under dist/PROGRAM. The download goes to a name of its own first, so that
# an interrupted one is never read as the package.
list_format() {
    format="$1"
    curl -fsSL --proto =https --proto-redir =https --retry 3 -o "$out/files/$3.part" "$site/$2/$3" ||
        fail "could not download $site/$2/$3"
    mv "$out/files/$3.part" "$out/files/$3"
    image="$(awk -v f="$format" '$1 == f { print $2; exit }' packaging/test-systems)"
    [ -n "$image" ] || fail "packaging/test-systems has no $format system"
    for pair in "published:/out/files/$3" "built:/built/$4"; do
        docker run --rm --entrypoint sh -e PROGRAM -e VERSION -e PACKAGE_DATE -e REVISION \
            -v "$root":/src:ro -v "$built":/built:ro -v "$out":/out -w /src "$image" \
            scripts/upgrade-test-"$format".sh list "${pair#*:}" > "$out/${pair%%:*}-$format" ||
            fail "could not read the ${pair%%:*} $format package"
    done
}

cpu="$(uname -m)"
case "$cpu" in
    x86_64 | amd64) deb_arch=amd64; rpm_arch=x86_64; apk_arch=x86_64 ;;
    aarch64 | arm64) deb_arch=arm64; rpm_arch=aarch64; apk_arch=aarch64 ;;
    *) fail "no package CPU type for $cpu" ;;
esac
initial="$(printf '%s' "$name" | cut -c1)"
old_deb="${name}_${old_debver}_$deb_arch.deb"
old_rpm="$name-$old_rpmver-$old_rpmrel.$rpm_arch.rpm"
old_apk="$name-$old_apkver-r$old_apkrel.$apk_arch.apk"
list_format deb "apt/pool/main/$initial/$name" "$old_deb" "${name}_${debver}_$deb_arch.deb"
list_format rpm "rpm/$rpm_arch" "$old_rpm" "$name-$rpmver-$rpmrel.$rpm_arch.rpm"
list_format apk "alpine/$apk_arch" "$old_apk" "alpine/$apk_arch/$name-$apkver-r$apkrel.apk"
