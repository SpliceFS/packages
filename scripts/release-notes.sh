#!/bin/sh
# Prints the notes of a release: the change log entries of every pull request merged since the
# previous version tag, oldest first. Run inside a full clone.
#
#   release-notes.sh <previous tag, or empty for the first release> <commit of the release>
#
# REPO is owner/name, for gh, and CHANGE_LOG_SCRIPT is the reader of a description (see
# change-log-entry.sh). A merge into main is a merge commit "Merge pull request #N from ...", and
# only merges on the first-parent line count: a merge of main into a branch is not a change of
# main. The description is read from GitHub and not from the repository, because that is where the
# author wrote it. A pull request without an entry stops the notes and is named, so that its
# description is fixed and the release made again; a release never goes out with a change
# missing from its notes.
set -eu

[ "$#" -eq 2 ] || { echo "usage: release-notes.sh <previous tag or empty> <commit>" >&2; exit 2; }
previous="$1"
commit="$2"
: "${REPO:?REPO is not set}"
here="$(cd "$(dirname "$0")" && pwd)"

range="$commit"
[ -z "$previous" ] || range="$previous..$commit"

numbers="$(git log --first-parent --merges --reverse --format=%s "$range" |
    sed -n 's/^Merge pull request #\([0-9][0-9]*\) from .*/\1/p')"

for number in $numbers; do
    # The login is the first line of the answer and the description is the rest.
    answer="$(gh api "repos/$REPO/pulls/$number" --jq '.user.login, (.body // "")')"
    login="$(printf '%s\n' "$answer" | sed -n 1p)"
    if ! printf '%s\n' "$answer" | sed 1d | sh "$here/change-log-entry.sh" "$login"; then
        echo "release-notes: pull request #$number has no usable change log entry" >&2
        exit 1
    fi
done
