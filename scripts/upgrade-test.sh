#!/bin/sh
# check-not-run: needs Docker, the network and the packages in dist/PROGRAM (make upgrade-test)
# Tests the upgrade of the program PROGRAM from the published package the build recorded (the
# newest on the package site when it recorded nothing) to the one in dist/PROGRAM, but only when the
# packaging changed: a version whose packages differ from the published ones only in the programs
# and the content of the documents (both come from the source of the program) cannot break an
# upgrade, so there is nothing to test. When the packaging changed and the new packages are of
# the same program version as the published ones (a change to the packaging alone is tested with
# the latest release and publishes nothing), the new package is reinstalled over the old one with
# the package manager's own command, which runs the upgrade scripts
# (scripts/upgrade-package-lib.sh). Runs on the host after make packages (make upgrade-test, CI). For each
# package format, for this machine's CPU type, it
#   1. downloads the published package of that format from the package site, which is what people
#      have installed (scripts/published-lib.sh), into dist/PROGRAM/published, and proves it by
#      the signed index of the site (scripts/published-verify.sh; apk does it when it installs),
#   2. lists the files, scripts and declarations of the published and the new package inside
#      a container of the format's first system in packaging/test-systems, and compares the
#      two lists (scripts/upgrade-diff.sh),
#   3. when they differ, installs the published package in a clean container, writes a
#      configuration line and a data file, installs the new package over it the way a user
#      upgrades, and checks that both survived, the service user exists, the new version is
#      installed, with the version that was built, and every file the new package
#      lists is there (scripts/upgrade-test-<format>.sh).
# Environment: PROGRAM; the version comes from dist/PROGRAM/version, which make packages wrote
# (scripts/package-record.sh), and a VERSION given must be that one; PLATFORM (linux/amd64 or
# linux/arm64) tests that CPU type by emulation, empty means this machine's own; PACKAGE_SITE
# (https://packages.splicefs.org). It keeps going after a failure so one run shows every format
# that is broken.
# What program.conf and the version words set is unknown to ShellCheck.
# shellcheck disable=SC2154
set -eu

: "${PROGRAM:?PROGRAM is not set}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# package-lib.sh reads files relative to the repository root.
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

# The published version to start from, the one the build recorded; the newest on the site when the
# record is empty. Empty when nothing is published. The functions of published-lib.sh are tests
# whose status is the answer, so set -e being off inside them changes nothing.
# shellcheck disable=SC2310
from="$(upgrade_from_version)" ||
    fail "could not read the newest published package of $PROGRAM from $site_url"

# What the published files are called is what package-lib.sh makes of the version of the published
# package.
published_dir="$root/dist/$PROGRAM/published"
if [ -n "$from" ]; then
    # A version that package_release_of_debver refuses ends the script here, with its message.
    use_published_version "$from"
    # The in-container scripts decide from it whether the new package is a reinstall or an upgrade.
    PUBLISHED_VERSION="$old_tag"
    export PUBLISHED_VERSION
fi

# The documents are installed under their own names, whatever folder they have in the source.
doc_names=""
for doc in $docs; do doc_names="$doc_names $(basename "$doc")"; done

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
    if boot_system --name "$container" --platform "$platform" -e PROGRAM -e VERSION -e PACKAGE_DATE -e PUBLISHED_VERSION \
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
    if [ -z "$from" ]; then
        echo "skip $format: no published version yet, nothing to upgrade from"
        skipped=$((skipped + 1))
        continue
    fi
    case "$format" in
        deb)
            new_file="${name}_${debver}_$deb_arch.deb"
            ;;
        rpm)
            new_file="$name-$rpmver-$rpmrel.$rpm_arch.rpm"
            ;;
        *)
            new_file="alpine/$apk_arch/$name-$apkver-r$apkrel.apk"
            ;;
    esac
    [ -f "dist/$PROGRAM/$new_file" ] || fail "dist/$PROGRAM/$new_file does not exist; run make packages first"

    old_path="$(published_path "$format" "$old_debver" "$old_rpmver" "$old_rpmrel" "$old_apkver" "$old_apkrel")"
    old_file="$(basename "$old_path")"
    # shellcheck disable=SC2310
    if ! download_published_file "$old_path" "$published_dir"; then
        echo "FAIL $format: could not download and verify $site_url/$old_path"
        failed=$((failed + 1))
        continue
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

    # The programs and the content of the documents come from the source of the program and are
    # not compared. The names are separated by spaces on purpose.
    set +e
    # shellcheck disable=SC2086
    differences="$(sh scripts/upgrade-diff.sh "$old_list" "$new_list" $programs -- $doc_names)"
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
    echo "$format: the packaging changed since $from, running the upgrade test:"
    printf '%s\n' "$differences"
    set +e
    in_container "upgrade-test-$format.sh" upgrade "/out/published/$old_file" "/out/$new_file" > "$log" 2>&1
    upgraded=$?
    set -e
    if [ "$upgraded" -eq 0 ]; then
        echo "ok   $format $image: $from upgraded to $VERSION"
        passed=$((passed + 1))
    else
        echo "FAIL $format $image"
        tail -n 15 "$log" | sed 's/^/     /'
        failed=$((failed + 1))
    fi
done

echo "passed: $passed  skipped: $skipped  failed: $failed"
[ "$failed" -eq 0 ]
