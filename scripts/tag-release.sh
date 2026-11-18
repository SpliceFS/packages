#!/bin/sh
# Puts the next version tag on a commit of main and makes the GitHub release of that tag. Run
# inside a full clone with all tags.
#
#   tag-release.sh <commit>
#
# The next version is the highest number tag plus one, and 1 when there is none (number-tags.sh
# says what a number tag is). The notes are the change log entries of the pull requests merged
# since that highest tag and a line for every program release published since then
# (release-notes.sh). A merge to main is only tagged once, so a second run for the same commit is
# refused. A program release is an event of its own: when PROGRAM_RELEASED is not empty the
# commit may have a number already, because the release of a program changes no pull request,
# and the number is the point of it. Which program is released is not told to this script, and
# the notes do not depend on it: they read the releases themselves.
#
# Needs REPO, CHANGE_LOG_SCRIPT (see release-notes.sh) and a GH_TOKEN of the release bot, because
# a tag made with the token of a workflow starts no workflow. The notes are made first, so that a
# pull request without an entry stops the release before it has a number. The tag is made before
# the release and the release is made from the tag, which starts the build as soon as possible.
# Two runs must not choose the same number: the workflow runs them one at a time, and a name that
# is taken makes the creation of the tag fail, so a second tag of a number is never made.
set -eu

[ "$#" -eq 1 ] || { echo "usage: tag-release.sh <commit>" >&2; exit 2; }
commit="$(git rev-parse --verify "$1^{commit}")"
: "${REPO:?REPO is not set}"
here="$(cd "$(dirname "$0")" && pwd)"

previous="$(git tag --list | sh "$here/number-tags.sh" | tail -n 1)"
next=$((${previous:-0} + 1))

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT

if [ -z "${PROGRAM_RELEASED:-}" ]; then
    have="$(git tag --points-at "$commit" | sh "$here/number-tags.sh" | tail -n 1)"
    if [ -n "$have" ]; then
        echo "tag-release: $commit already has the version tag $have; it is not tagged again" >&2
        exit 1
    fi
fi
sh "$here/release-notes.sh" "$previous" "$commit" > "$notes"

gh api "repos/$REPO/git/refs" -f "ref=refs/tags/$next" -f "sha=$commit" --silent
gh release create "$next" --repo "$REPO" --verify-tag --title "$next" --notes-file "$notes"
echo "tagged $commit as $next"
