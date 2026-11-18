#!/bin/sh
# Refuses a run that is not a release of main, before any key is written. The signing and upload
# keys belong to the environment publish, which lets a run use them for any tag that is a whole
# number, and a tag can sit on any commit of any branch. So the run itself checks that it is for a
# number tag (1, 2, 3, ...) and that the commit of the tag is on main.
# Usage: release-tag-check.sh REF_TYPE REF_NAME COMMIT    (GITHUB_REF_TYPE, GITHUB_REF_NAME and
# GITHUB_SHA in a workflow). Run it inside a checkout that holds the whole history.
set -eu

[ "$#" -eq 3 ] && [ -n "$1" ] || { echo "usage: release-tag-check.sh REF_TYPE REF_NAME COMMIT" >&2; exit 2; }
ref_type="$1"
tag="$2"
commit="$3"

[ "$ref_type" = tag ] || { echo "::error::this run is for the $ref_type $tag, which is not a tag, so it cannot publish" >&2; exit 1; }
case "$tag" in
    '' | 0* | *[!0-9]*) echo "::error::the tag $tag is not a number like 12, so it is not a release" >&2; exit 1 ;;
    *) ;;
esac
# Fetched by name, so that main is the tip it has now and not the state of the last checkout.
git fetch --no-tags origin main
if ! git merge-base --is-ancestor "$commit" FETCH_HEAD; then
    echo "::error::the commit of the tag $tag is not on main, so it cannot be released" >&2
    exit 1
fi
