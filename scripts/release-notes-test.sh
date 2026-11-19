#!/bin/sh
# check: release-notes.sh: the notes of a release are the entries of the pull requests merged since the last tag
# Test of scripts/release-notes.sh: the notes of a release are the change log entries of the
# pull requests merged since the previous version tag, then one line for every program release
# published from the cut time of the previous version up to the cut time of this one, then the
# line that records this cut time. Runs on the host, no network (part of make check): the
# repository is a throwaway one, gh is a stand-in that answers from files, and the reader of a
# description is a stand-in with the contract of the shared one.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
mkdir "$work/bin" "$work/answers"

# The stand-in records what was asked and prints what gh prints after its --jq: for a pull
# request two things, the login of the author, then the description (file pr-N); for the release
# of a version tag its notes (file tag-NAME); for the releases of a repository a
# line "time TAB tag" for each published one (file releases-OWNER-NAME). A file that is missing
# is a request that fails.
cat > "$work/bin/gh" <<'GH'
#!/bin/sh
[ "$1" = api ] || exit 2
printf '%s\n' "$2" >> "$ANSWERS/asked"
case "$2" in
    repos/*/pulls/*) cat "$ANSWERS/pr-${2##*/}" ;;
    repos/*/releases/tags/*) cat "$ANSWERS/tag-${2##*/}" ;;
    repos/*/releases) cat "$ANSWERS/releases-$(echo "${2#repos/}" | cut -d/ -f1,2 | tr / -)" ;;
    *) exit 2 ;;
esac
GH
chmod +x "$work/bin/gh"
cat > "$work/reader.sh" <<'READER'
#!/bin/sh
body="$(cat)"
if printf '%s\n' "$body" | grep -q '^## Change log'; then
    printf '%s\n' "$body" | grep '^- '
elif [ -n "${DEFAULT_ENTRY:-}" ]; then
    printf -- '- %s\n' "$DEFAULT_ENTRY"
else
    echo "change_log: missing" >&2
    exit 1
fi
READER

# $1 number, $2 author, $3 description of a pull request, as the API tells it.
pull_request() {
    printf '%s\n%s\n' "$2" "$3" > "$work/answers/pr-$1"
}
pull_request 4 alice "## Change log

- Entry four."
pull_request 5 alice "## Change log

- Entry five.
- Entry five, second line."
pull_request 6 'dependabot[bot]' "Bumps a thing."
pull_request 7 alice "No section at all."

# The notes of a release, as GitHub keeps them: the entries, then the line with its cut time.
# $1 version, $2 its cut time, $3 what comes before each line end (a carriage return or nothing).
release_notes_of() {
    printf 'Notes.%s\n%s\n<!-- cut: %s -->%s\n' "$3" "$3" "$2" "$3" > "$work/answers/tag-$1"
}
# The versions 1, 2 and 3 were cut on 2026-11-02, -04 and -06, at 10:00. The notes of the version
# 3 were edited on the web page, which gives them Windows line ends. The version 5 has notes
# without a cut line, and the version 4 has no release.
release_notes_of 1 2026-11-02T10:00:00Z ""
release_notes_of 2 2026-11-04T10:00:00Z ""
release_notes_of 3 2026-11-06T10:00:00Z "$(printf '\r')"
printf 'Notes without a cut line.\n' > "$work/answers/tag-5"
# The releases of the two programs, told apart by their time. A release counts from the cut time
# of the previous version (it is in the notes of the next version when it is published at that
# very second) up to, and not including, the cut time of this version: before the version 1, at
# the cut of 1, between 1 and 2, at the cut of 2, after 2.
tab="$(printf '\t')"
printf '%s\n' "2026-11-01T09:00:00Z${tab}v0.5.34" "2026-11-02T10:00:00Z${tab}v0.5.35" \
    "2026-11-03T12:00:00Z${tab}v0.5.36" "2026-11-05T12:00:00Z${tab}v0.5.37" \
    "2026-11-04T10:00:00Z${tab}v0.5.38" \
    > "$work/answers/releases-example-server"
printf '%s\n' "2026-11-03T08:00:00Z${tab}v0.2.1" > "$work/answers/releases-example-client"

repo="$work/repo"
git init -q -b main "$repo"
git="git -C $repo -c user.name=tester -c user.email=tester@example.com -c commit.gpgsign=false"
# A pull request is a branch with one commit, merged with a merge commit as GitHub does.
merge() {
    $git checkout -q -b "pr-$1"
    $git commit -q --allow-empty -m "change $1"
    $git checkout -q main
    $git merge -q --no-ff -m "Merge pull request #$1 from owner/pr-$1" "pr-$1"
}
# The programs of the repository, with the repository each one is released from.
for program in client server; do
    mkdir -p "$repo/programs/$program"
    printf 'name=splicefs-%s\nprogram=x\nprograms=x\ndocs=x\nrelease_repo=example/%s\n' \
        "$program" "$program" > "$repo/programs/$program/program.conf"
done
$git add programs
$git commit -q -m "start"
merge 4
$git tag 1
$git commit -q --allow-empty -m "a commit pushed straight to main"
merge 5
$git commit -q --allow-empty -m "Merge branch 'main' into somewhere"
merge 6
$git tag 2
merge 7
$git tag 3
$git tag 4
$git tag 5

# $1 case name, $2 previous tag (may be empty), $3 the commit, $4 the cut time of the release,
# $5 status wanted, $6 output wanted.
notes() {
    status=0
    got="$(cd "$repo" && ANSWERS="$work/answers" PATH="$work/bin:$PATH" REPO=owner/repo \
        CHANGE_LOG_SCRIPT="$work/reader.sh" sh "$root/scripts/release-notes.sh" "$2" "$3" "$4" 2>"$work/err")" || status=$?
    if [ "$status" -eq "$5" ] && [ "$got" = "$6" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want %s "%s" got %s "%s"\n' "$1" "$5" "$6" "$status" "$got"
        failed=$((failed + 1))
    fi
}

notes "the pull requests and the program releases from the previous cut up to this one, oldest first, and the cut line" 1 2 2026-11-04T10:00:00Z 0 "- Entry five.
- Entry five, second line.
- Internal: a dependency is updated. Nothing changes for users.
- Release of server v0.5.35.
- Release of client v0.2.1.
- Release of server v0.5.36.
<!-- cut: 2026-11-04T10:00:00Z -->"
: > "$work/answers/asked"
notes "without a previous tag every pull request counts, no release does, and the cut is recorded" "" 2 2026-11-02T10:00:00Z 0 "- Entry four.
- Entry five.
- Entry five, second line.
- Internal: a dependency is updated. Nothing changes for users.
<!-- cut: 2026-11-02T10:00:00Z -->"
if grep -q releases "$work/answers/asked"; then
    echo "FAIL no release is asked for without a previous tag"
    failed=$((failed + 1))
else
    echo "ok   no release is asked for without a previous tag"
fi
# The releases at the cut of the version 2 and after it are the ones the notes above left out:
# together the two sets hold every release from the cut of 1 on, once.
notes "a release alone, with no pull request merged; one published at the previous cut is in it" 2 2 2026-11-06T10:00:00Z 0 "- Release of server v0.5.38.
- Release of server v0.5.37.
<!-- cut: 2026-11-06T10:00:00Z -->"
notes "nothing merged and nothing released since the previous cut, only the cut line; a cut line with Windows line ends is read" 3 3 2026-11-07T10:00:00Z 0 "<!-- cut: 2026-11-07T10:00:00Z -->"
notes "a previous tag without a release of its own stops the notes" 4 4 2026-11-07T10:00:00Z 1 ""
err="$(cat "$work/err")"
if printf '%s\n' "$err" | grep -q 'version tag 4 has no release'; then echo "ok   the failure names the tag"; else
    echo "FAIL the failure names the tag: $err"
    failed=$((failed + 1))
fi
notes "a previous release without a cut line stops the notes" 5 5 2026-11-07T10:00:00Z 1 ""
err="$(cat "$work/err")"
if printf '%s\n' "$err" | grep -q 'release 5 has no cut line'; then echo "ok   the failure names the release"; else
    echo "FAIL the failure names the release: $err"
    failed=$((failed + 1))
fi
: > "$work/answers/asked"
notes "the pull request that has no change log section stops the notes" 2 main 2026-11-07T10:00:00Z 1 ""
err="$(cat "$work/err")"
if printf '%s\n' "$err" | grep -q '#7'; then echo "ok   the failure names the pull request"; else
    echo "FAIL the failure names the pull request: $err"
    failed=$((failed + 1))
fi
asked="$(grep /pulls/ "$work/answers/asked")"
if [ "$asked" = "repos/owner/repo/pulls/7" ]; then
    echo "ok   only the pull requests of the range are asked for"
else
    echo "FAIL only the pull requests of the range are asked for: $asked"
    failed=$((failed + 1))
fi

# The program that is released from a repository it does not name stops the notes: a release
# would go out with a program release missing.
printf 'name=x\nprogram=x\nprograms=x\ndocs=x\n' > "$repo/programs/server/program.conf"
notes "a program that names no release repository stops the notes" 2 2 2026-11-07T10:00:00Z 1 ""
err="$(cat "$work/err")"
if printf '%s\n' "$err" | grep -q 'programs/server/program.conf does not set release_repo'; then
    echo "ok   the failure names the program file"
else
    echo "FAIL the failure names the program file: $err"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "release-notes: all cases as expected"
