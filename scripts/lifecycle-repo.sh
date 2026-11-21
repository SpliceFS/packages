#!/bin/sh
# Collects the packages of the test repository of the program PROGRAM in dist/lifecycle/PROGRAM:
# the new packages of dist/PROGRAM and the newest package of the program on the package site at the
# time of the build (UPGRADE_FROM of the version record; the newest on the site when it is empty),
# so that the repository is what a publish would make (scripts/repo-*.sh keep the older
# version next to the new one). The published packages are downloaded from the site the way the
# upgrade test does (scripts/published-lib.sh) for this machine's CPU type. They were made with the
# release key, which the test repository does not have: the Alpine ones, the new ones too, are
# signed again with the key of dist/keys (scripts/apk-resign.sh, the make target lifecycle-repo runs
# it after this script); the others are signed by the repository step. The program version of the
# published package is written to dist/lifecycle/PROGRAM/published for the test.
# Runs on the host (make lifecycle-test). Needs curl. Environment: PROGRAM; PLATFORM;
# PACKAGE_SITE (https://packages.splicefs.org).
set -eu

: "${PROGRAM:?PROGRAM is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
. scripts/published-lib.sh

platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
case "$platform" in
    linux/amd64) deb_arch=amd64; rpm_arch=x86_64; apk_arch=x86_64 ;;
    linux/arm64) deb_arch=arm64; rpm_arch=aarch64; apk_arch=aarch64 ;;
    *) fail "no package CPU type for $platform" ;;
esac

# shellcheck disable=SC2310
from="$(upgrade_from_version)" || fail "could not read the newest published package of $PROGRAM from $site_url"
[ -n "$from" ] || fail "nothing is published of $PROGRAM at $site_url; the lifecycle test starts from the published package"
use_published_version "$from"

out="dist/lifecycle/$PROGRAM"
published="dist/$PROGRAM/published"
rm -rf "$out"
mkdir -p "$out/alpine/$apk_arch"

# The published packages go first and the new ones after them. A change to the packaging alone
# keeps the program version, so a published package can have the name of a new one, and the new one
# must be the one that stays.
for format in deb rpm apk; do
    path="$(published_path "$format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
    # shellcheck disable=SC2310
    download_published_file "$path" "$published" || fail "could not download and verify $site_url/$path"
    # The published files are where the repository step finds the packages of a format: an Alpine
    # package in the folder of its CPU type, the others beside the new ones.
    case "$format" in
        apk) cp "$published/$(basename "$path")" "$out/alpine/$apk_arch/" ;;
        *) cp "$published/$(basename "$path")" "$out/" ;;
    esac
done
cp dist/"$PROGRAM"/*.deb dist/"$PROGRAM"/*.rpm "$out/"
# The new Alpine packages were signed with the key of the build that made them. The server and
# the client are built in runs of their own, with keys of their own, so they are signed again with
# the key of this repository, as the published ones are.
for apk in dist/"$PROGRAM"/alpine/*/*.apk; do
    arch="$(basename "$(dirname "$apk")")"
    mkdir -p "$out/alpine/$arch"
    cp "$apk" "$out/alpine/$arch/"
done
printf 'TAG=%s\n' "$old_tag" > "$out/published"
echo "collected the new packages and $old_tag in $out"
