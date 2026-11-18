#!/bin/sh
# Collects the packages of the test repository of the program PROGRAM in dist/lifecycle/PROGRAM:
# the new packages of dist/PROGRAM and the published release they were built next to (UPGRADE_FROM
# of the version record; the newest release when the record has none), so that the repository is
# what a release would publish (scripts/repo-*.sh keep the older version next to the new one).
# The published packages are downloaded the way the upgrade test does (scripts/published-lib.sh)
# for this machine's CPU type. They were made with the release key, which the test repository
# does not have: the Alpine ones, the new ones too, are signed again with the key of dist/keys
# (scripts/apk-resign.sh, the make target lifecycle-repo runs it after this script); the others
# are signed by the repository step. The tag of the published release is written to
# dist/lifecycle/PROGRAM/published for the test. Runs on the host (make lifecycle-test). Needs
# curl. Environment: PROGRAM; PLATFORM.
set -eu

: "${PROGRAM:?PROGRAM is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
. scripts/published-lib.sh
: "${release_repo:?$defs/program.conf does not set release_repo, the repository the program is released from}"

platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
case "$platform" in
    linux/amd64) deb_arch=amd64; rpm_arch=x86_64; apk_arch=x86_64 ;;
    linux/arm64) deb_arch=arm64; rpm_arch=aarch64; apk_arch=aarch64 ;;
    *) fail "no package CPU type for $platform" ;;
esac

# shellcheck disable=SC2310
tag="$(upgrade_from_tag "$release_repo")" || fail "could not ask for the newest release of $release_repo"
[ -n "$tag" ] || fail "$release_repo has no release; the lifecycle test starts from the published one"
# shellcheck disable=SC2310
names="$(release_versions "$tag")" || fail "could not work out the file names of $tag"
read -r old_debver old_rpmver old_rpmrel old_apkver old_apkrel _ <<LIST
$names
LIST

out="dist/lifecycle/$PROGRAM"
published="dist/$PROGRAM/published"
rm -rf "$out"
mkdir -p "$out/alpine/$apk_arch"
cp dist/"$PROGRAM"/*.deb dist/"$PROGRAM"/*.rpm "$out/"
# The new Alpine packages were signed with the key of the build that made them. The server and
# the client are built in runs of their own, with keys of their own, so they are signed again with
# the key of this repository, as the published ones are.
for apk in dist/"$PROGRAM"/alpine/*/*.apk; do
    arch="$(basename "$(dirname "$apk")")"
    mkdir -p "$out/alpine/$arch"
    cp "$apk" "$out/alpine/$arch/"
done

for format in deb rpm apk; do
    file="$(release_file_name "$format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
    # shellcheck disable=SC2310
    download_release_file "$release_repo" "$tag" "$file" "$published" ||
        fail "could not download https://github.com/$release_repo/releases/download/$tag/$file"
    case "$format" in
        apk)
            cp "$published/$file" "$out/alpine/$apk_arch/$name-$old_apkver-r$old_apkrel.apk"
            ;;
        *) cp "$published/$file" "$out/" ;;
    esac
done
printf 'TAG=%s\n' "$tag" > "$out/published"
echo "collected the new packages and $tag in $out"
