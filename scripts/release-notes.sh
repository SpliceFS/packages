#!/bin/sh
# Prints the notes of a release: the change log entries of every pull request merged since the
# previous version tag, oldest first, then one line for every release of a program published
# since that tag, oldest first. Run inside a full clone, at its root.
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
#
# A program release is a release of a program (a folder of programs/) in its own repository,
# named by release_repo in programs/PROGRAM/program.conf. It is read from there and not from a
# message of the program's workflow, because a message can be lost or replaced and the releases
# cannot. The previous version covers the releases published up to the moment its own release
# was published, so a program release is in the notes of exactly one version. The first release
# has no previous version and no program release lines: the programs were released before it.
set -eu

[ "$#" -eq 2 ] || { echo "usage: release-notes.sh <previous tag or empty> <commit>" >&2; exit 2; }
previous="$1"
commit="$2"
: "${REPO:?REPO is not set}"
here="$(cd "$(dirname "$0")" && pwd)"

# The repository a program is released from. program-conf.sh is the one place that says what a
# program is, so the file is read through it, in a shell of its own.
release_repo_of() {
    (
        PROGRAM="$1"
        # shellcheck source=program-conf.sh
        . "$here/program-conf.sh"
        [ -n "${release_repo:-}" ] || fail "$defs/program.conf does not set release_repo"
        echo "$release_repo"
    )
}

# $1 program, $2 the time after which a release counts. Prints "time TAB program TAB tag" for
# each. Times are in the one form GitHub uses, so that they compare as text. A draft has no
# time and is not a release yet.
program_releases() {
    repo="$(release_repo_of "$1")"
    published="$(gh api "repos/$repo/releases" --paginate \
        --jq '.[] | select(.draft == false and .published_at != null) | [.published_at, .tag_name] | @tsv')" ||
        { echo "release-notes: the releases of $repo cannot be read" >&2; return 1; }
    printf '%s\n' "$published" |
        awk -F '\t' -v since="$2" -v program="$1" '$1 > since { print $1 "\t" program "\t" $2 }'
}

pull_request_notes() {
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
}

program_release_notes() {
    [ -n "$previous" ] || return 0
    since="$(gh api "repos/$REPO/releases/tags/$previous" --jq '.published_at // empty')" || since=""
    [ -n "$since" ] || {
        echo "release-notes: the version tag $previous has no release, so the time of that version is not known" >&2
        exit 1
    }

    releases=""
    for conf in programs/*/program.conf; do
        program="$(basename "$(dirname "$conf")")"
        # Not in a pipe: a failure of the function must stop the notes, not only the sort.
        found="$(program_releases "$program" "$since")"
        releases="$releases$found
"
    done
    printf '%s' "$releases" | sed '/^$/d' | sort |
        awk -F '\t' '{ printf "- Release of %s %s.\n", $2, $3 }'
}

pull_request_notes
program_release_notes
