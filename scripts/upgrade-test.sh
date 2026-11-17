#!/bin/sh
# Tests the upgrade of the program PROGRAM from the newest published version to the one in
# dist/PROGRAM, but only when the packaging changed: a version whose packages differ from the
# published ones only in the programs (and the changelog) cannot break an upgrade, so there is
# nothing to test. When the packaging changed and the new packages are of the same program
# version as the published ones, they must be a later revision of it (make packages REVISION=N),
# because a package of the same version and revision is no upgrade: rpm refuses it, and deb and
# apk reinstall it without a word, which would hide the problem. Runs on the host after make
# packages (make upgrade-test, CI). For each
# package format, for this machine's CPU type, it
#   1. downloads the newest published package of that format from the GitHub release of the
#      repository the program is released from (release_repo in programs/PROGRAM/program.conf)
#      into dist/PROGRAM/published,
#   2. lists the files, scripts and declarations of the published and the new package inside
#      a container of the format's first system in packaging/test-systems, and compares the
#      two lists (scripts/upgrade-diff.sh),
#   3. when they differ, installs the published package in a clean container, writes a
#      configuration line and a data file, installs the new package over it the way a user
#      upgrades, and checks that both survived, the service user exists, the new version is
#      installed, with the version and revision that were built, and every file the new package
#      lists is there (scripts/upgrade-test-<format>.sh).
# Environment: PROGRAM; the version comes from dist/PROGRAM/version, which make packages wrote
# (scripts/package-record.sh), and a VERSION given must be that one; PLATFORM (linux/amd64 or
# linux/arm64) tests that CPU type by emulation, empty means this machine's own. It keeps going
# after a failure so one run shows every format that is broken.
# release_repo is set by the program.conf of the program, which is chosen at run time, so
# ShellCheck cannot follow it.
# shellcheck disable=SC2154
set -eu

: "${PROGRAM:?PROGRAM is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
cd "$root"
. scripts/package-record.sh
use_recorded_version
. scripts/package-lib.sh
: "${release_repo:?$defs/program.conf does not set release_repo, the repository the program is released from}"

releases="https://github.com/$release_repo/releases"
platform="${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
case "$platform" in
    linux/amd64) deb_arch=amd64; rpm_arch=x86_64; apk_arch=x86_64 ;;
    linux/arm64) deb_arch=arm64; rpm_arch=aarch64; apk_arch=aarch64 ;;
    *) fail "no package CPU type for $platform" ;;
esac

# Both downloads insist on HTTPS, also after a redirect, so that a redirect can never hand
# over a package from a plain address.
# The tag of the newest release. GitHub answers with the releases page itself when there is
# none; a network failure is a failure of this script and not a reason to skip.
final_url="$(curl -fsSIL --proto =https --proto-redir =https --retry 3 -o /dev/null -w '%{url_effective}' "$releases/latest")" ||
    fail "could not ask $releases/latest for the newest release"
case "$final_url" in
    */releases/tag/*) tag="${final_url##*/}" ;;
    *) tag="" ;;
esac

# The packages attached to the release of a program are the revision 0 of that version: they
# are made when the program is released. A later revision of the same version is a change to the
# packaging alone and goes to the package repository, never to the release. So the published
# packages this test upgrades from are revision 0, and what they are called is what
# package-lib.sh makes of the tag and that revision.
released_revision=0
published_dir="$root/dist/$PROGRAM/published"
if [ -n "$tag" ]; then
    # A version that package_versions refuses ends the script here, with its message.
    names="$(package_versions "$tag" "$released_revision" "$PACKAGE_DATE")"
    read -r old_debver old_rpmver old_rpmrel old_apkver old_apkrel _ <<LIST
$names
LIST
fi

log="$(mktemp)"
old_list="$(mktemp)"
new_list="$(mktemp)"
container="splicefs-upgrade-test-$$"
cleanup() {
    rm -f "$log" "$old_list" "$new_list"
    docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
passed=0
skipped=0
failed=0

# Runs scripts/upgrade-test-<format>.sh in a clean, booted container of $image with the
# repository at /src and dist at /out, both read-only; the container is gone afterwards, so
# every run starts from the image. Arguments: the script name, then its own.
in_container() {
    script="$1"
    shift
    # Each step runs only when the one before it worked; the conditions are tests whose
    # status is the answer.
    # shellcheck disable=SC2310
    if boot_system --name "$container" --platform "$platform" -e PROGRAM -e VERSION -e PACKAGE_DATE -e REVISION \
        -v "$root":/src:ro -v "$root/dist/$PROGRAM":/out:ro -w /src "$image" &&
        wait_booted "$format" "$container"; then
        status=0
        docker exec "$container" sh "scripts/$script" "$@" || status=$?
    else
        status=1
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$status"
}

for format in deb rpm apk; do
    # The first system of the format is the one tested, the same as for the other tests.
    image="$(awk -v f="$format" '$1 == f { print $2; exit }' packaging/test-systems)"
    [ -n "$image" ] || fail "packaging/test-systems has no $format system"
    if [ -z "$tag" ]; then
        echo "skip $format: no published version yet, nothing to upgrade from"
        skipped=$((skipped + 1))
        continue
    fi
    case "$format" in
        deb)
            old_file="${name}_${old_debver}_$deb_arch.deb"
            new_file="${name}_${debver}_$deb_arch.deb"
            ;;
        rpm)
            old_file="$name-$old_rpmver-$old_rpmrel.$rpm_arch.rpm"
            new_file="$name-$rpmver-$rpmrel.$rpm_arch.rpm"
            ;;
        *)
            old_file="$name-$old_apkver-r$old_apkrel.$apk_arch.apk"
            new_file="alpine/$apk_arch/$name-$apkver-r$apkrel.apk"
            ;;
    esac
    [ -f "dist/$PROGRAM/$new_file" ] || fail "dist/$PROGRAM/$new_file does not exist; run make packages first"

    mkdir -p "$published_dir"
    if [ ! -f "$published_dir/$old_file" ]; then
        # Written under another name first, so an interrupted download is never mistaken
        # for the package.
        if ! curl -fsSL --proto =https --proto-redir =https --retry 3 -o "$published_dir/$old_file.part" "$releases/download/$tag/$old_file" ||
            ! mv "$published_dir/$old_file.part" "$published_dir/$old_file"; then
            rm -f "$published_dir/$old_file.part"
            echo "FAIL $format: could not download $releases/download/$tag/$old_file"
            failed=$((failed + 1))
            continue
        fi
    fi

    # A registry failure must not look like a failed upgrade.
    # Errexit is off for the call to read its status; pull_image checks every command itself.
    set +e
    pull_image "$platform" "$image"
    pulled=$?
    set -e
    if [ "$pulled" -ne 0 ]; then
        echo "FAIL $format $image: could not download the image (3 tries)"
        failed=$((failed + 1))
        continue
    fi

    set +e
    in_container "upgrade-test-$format.sh" list "/out/published/$old_file" > "$old_list" 2> "$log"
    listed=$?
    if [ "$listed" -eq 0 ]; then
        in_container "upgrade-test-$format.sh" list "/out/$new_file" > "$new_list" 2> "$log"
        listed=$?
    fi
    set -e
    if [ "$listed" -ne 0 ]; then
        echo "FAIL $format $image: could not read the packages"
        tail -n 15 "$log" | sed 's/^/     /'
        failed=$((failed + 1))
        continue
    fi

    # The programs and the changelog change in every version and are not compared. The names
    # of the programs are separated by spaces on purpose.
    set +e
    # shellcheck disable=SC2086
    differences="$(sh scripts/upgrade-diff.sh "$old_list" "$new_list" $programs CHANGELOG.md)"
    compared=$?
    set -e
    if [ "$compared" -eq 0 ]; then
        echo "$format: only the program changed; no upgrade test needed"
        passed=$((passed + 1))
        continue
    fi
    if [ "$compared" -ne 1 ]; then
        echo "FAIL $format: could not compare the packages"
        failed=$((failed + 1))
        continue
    fi
    echo "$format: the packaging changed since $tag, running the upgrade test:"
    printf '%s\n' "$differences"
    # The same program version needs a later revision, or the format sees no upgrade.
    if [ "$VERSION" = "$tag" ] && [ "$REVISION" -le "$released_revision" ]; then
        echo "FAIL $format: the packaging changed since $tag, which is the version of these packages too, but their revision is $REVISION and the published ones are revision $released_revision: build them with REVISION=$((released_revision + 1)) or more"
        failed=$((failed + 1))
        continue
    fi

    set +e
    in_container "upgrade-test-$format.sh" upgrade "/out/published/$old_file" "/out/$new_file" > "$log" 2>&1
    upgraded=$?
    set -e
    if [ "$upgraded" -eq 0 ]; then
        echo "ok   $format $image: $tag upgraded to $VERSION revision $REVISION"
        passed=$((passed + 1))
    else
        echo "FAIL $format $image"
        tail -n 15 "$log" | sed 's/^/     /'
        failed=$((failed + 1))
    fi
done

echo "passed: $passed  skipped: $skipped  failed: $failed"
[ "$failed" -eq 0 ]
