#!/bin/sh
# Prints the notes of a release: the change log entries of every pull request merged since the
# previous version tag, oldest first, then one line for every release of a program published
# between the cut time of the previous version and the cut time of this one, oldest first, then
# one line that records this cut time. Run inside a full clone, at its root.
#
#   release-notes.sh <previous tag, or empty for the first release> <commit of the release> <cut time>
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
# cannot.
#
# The cut time is the moment the caller started to make this version (an UTC time like
# 2026-11-17T15:00:00Z), taken before anything was read. It ends this version and starts the
# next: a release is in the version for which previous cut <= published < this cut, so no release
# is in two versions and none is left out. A release published before the cut can be read when
# the reading starts, and one published after it is for the next version, even when it appears
# while this release is being made. For that reason the next version reads the cut from the end
# of these notes, where it is written in a comment that GitHub does not show, and not the time
# this release was published. The first release has no previous version and no program release
# lines: the programs were released before it. A previous release without the line stops the
# notes, because the start is not known.
set -eu

[ "$#" -eq 3 ] || { echo "usage: release-notes.sh <previous tag or empty> <commit> <cut time>" >&2; exit 2; }
previous="$1"
commit="$2"
cut="$3"
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

# $1 program, $2 the time a release counts from, $3 the time before which it counts. Prints "time
# TAB program TAB tag" for each. Times are in the one form GitHub uses, so that they compare as
# text. A draft has no time and is not a release yet.
program_releases() {
    repo="$(release_repo_of "$1")"
    published="$(gh api "repos/$repo/releases" --paginate \
        --jq '.[] | select(.draft == false and .published_at != null) | [.published_at, .tag_name] | @tsv')" ||
        { echo "release-notes: the releases of $repo cannot be read" >&2; return 1; }
    printf '%s\n' "$published" |
        awk -F '\t' -v from="$2" -v until="$3" -v program="$1" \
            '$1 >= from && $1 < until { print $1 "\t" program "\t" $2 }'
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

# The line that records the cut time in the notes, and the reader of it. They are the one place
# that knows the form of the line.
cut_line() {
    printf '<!-- cut: %s -->\n' "$cut"
}

# $1 the version tag. Prints the cut time its release records. A body edited on the web page has
# Windows line ends.
recorded_cut() {
    body="$(gh api "repos/$REPO/releases/tags/$1" --jq '.body // ""')" || {
        echo "release-notes: the version tag $1 has no release, so the time of that version is not known" >&2
        return 1
    }
    since="$(printf '%s\n' "$body" | tr -d '\r' |
        sed -n 's/^<!-- cut: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z\) -->$/\1/p' |
        tail -n 1)"
    [ -n "$since" ] || {
        echo "release-notes: the release $1 has no cut line, so the time of that version is not known" >&2
        return 1
    }
    echo "$since"
}

program_release_notes() {
    [ -n "$previous" ] || return 0
    since="$(recorded_cut "$previous")"

    releases=""
    for conf in programs/*/program.conf; do
        program="$(basename "$(dirname "$conf")")"
        # Not in a pipe: a failure of the function must stop the notes, not only the sort.
        found="$(program_releases "$program" "$since" "$cut")"
        releases="$releases$found
"
    done
    printf '%s' "$releases" | sed '/^$/d' | sort |
        awk -F '\t' '{ printf "- Release of %s %s.\n", $2, $3 }'
}

pull_request_notes
program_release_notes
cut_line
