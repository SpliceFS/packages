#!/bin/sh
# Decides whether the packaging of this repository, as it is now, is published as a package
# revision of the current release of a program. It is when the packages built from the release
# differ from the packages published for it, in any format, in anything but the program and the
# changelog (scripts/upgrade-diff.sh, the same comparison the upgrade test makes). A change that
# touches only tests, documents or workflows builds the same packages and so publishes nothing.
# A release that is not published at all is left to the publish of the release itself.
# Usage: revision-decide.sh PROGRAM TAG LISTINGS_DIR
#   LISTINGS_DIR holds published-FORMAT and built-FORMAT for deb, rpm and apk: the package
#   listings of scripts/upgrade-lib.sh, of the newest published revision of the release and of
#   the packages built now (scripts/revision-listings.sh makes them).
# Output: "PROGRAM TAG" on the standard output when a revision must be published, nothing when
# not; the reason is on the standard error. The revision itself is not decided here: the publish
# run computes it after it has waited for the runs before it (scripts/next-revision.sh).
# Environment: INDEX_FILE and PACKAGE_SITE as in scripts/next-revision.sh. Runs on the host.
set -eu

PROGRAM="${1:?usage: revision-decide.sh PROGRAM TAG LISTINGS_DIR}"
TAG="${2:?usage: revision-decide.sh PROGRAM TAG LISTINGS_DIR}"
LISTINGS="${3:?usage: revision-decide.sh PROGRAM TAG LISTINGS_DIR}"
export PROGRAM
cd "$(dirname "$0")/.."
# shellcheck source=program-conf.sh
. scripts/program-conf.sh

next="$(sh scripts/next-revision.sh "$PROGRAM" "$TAG")"
if [ "$next" = 0 ]; then
    echo "$TAG of $PROGRAM is not published yet: nothing to revise" >&2
    exit 0
fi

# The listings are checked first, so that a missing one is never read as "nothing differs".
for format in deb rpm apk; do
    for kind in published built; do
        [ -f "$LISTINGS/$kind-$format" ] || fail "$LISTINGS/$kind-$format is missing"
    done
done

changed=0
for format in deb rpm apk; do
    # The names are separated by spaces on purpose. Status 1 is a difference, which is an
    # answer here and no error.
    status=0
    # shellcheck disable=SC2086,SC2154 # programs is set by program.conf
    differences="$(sh scripts/upgrade-diff.sh "$LISTINGS/published-$format" "$LISTINGS/built-$format" $programs CHANGELOG.md)" || status=$?
    case "$status" in
        0) ;;
        1)
            echo "$format: the packaging differs from the published revision $((next - 1)) of $TAG:" >&2
            printf '%s\n' "$differences" >&2
            changed=1
            ;;
        *) fail "could not compare the $format packages" ;;
    esac
done

if [ "$changed" -eq 0 ]; then
    echo "$PROGRAM $TAG: the packaging is the same as the published revision $((next - 1)): nothing to publish" >&2
    exit 0
fi
echo "$PROGRAM $TAG"
