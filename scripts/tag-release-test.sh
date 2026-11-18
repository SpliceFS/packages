#!/bin/sh
# Test of scripts/tag-release.sh: the next version tag is put on a commit of main and a GitHub
# release is made for it. Runs on the host, no network (part of make check): the repository is a
# throwaway one and gh is a stand-in that records what it was asked to do.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
mkdir "$work/bin" "$work/answers"

# The stand-in answers the lookups of pull requests, of the release of a version (when it was
# published) and of the program releases from files, and records the other calls in "calls": the
# tag as "tag NAME SHA", the release as "release NAME" and its notes in notes-NAME. FAIL_TAG makes
# the creation of the tag fail, as it does when the name is already taken.
cat > "$work/bin/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
    "api repos/owner/repo/pulls/"*)
        cat "$ANSWERS/pr-${2##*/}" ;;
    "api repos/owner/repo/releases/tags/"*)
        cat "$ANSWERS/tag-${2##*/}" ;;
    "api repos/example/server/releases")
        cat "$ANSWERS/server-releases" ;;
    "api repos/owner/repo/git/refs")
        [ -z "${FAIL_TAG:-}" ] || exit 1
        echo "tag ${4#ref=refs/tags/} ${6#sha=}" >> "$ANSWERS/calls" ;;
    "release create")
        name="$3"
        echo "release $name" >> "$ANSWERS/calls"
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --notes-file ]; then cp "$2" "$ANSWERS/notes-$name"; fi
            shift
        done ;;
    *) echo "unexpected: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$work/bin/gh"
cat > "$work/reader.sh" <<'READER'
#!/bin/sh
grep '^- '
READER
printf 'alice\n## Change log\n\n- Entry four.\n' > "$work/answers/pr-4"
printf 'alice\n## Change log\n\n- Entry five.\n' > "$work/answers/pr-5"
# The version 1 was published on 2026-11-02 and the version 2 on 2026-11-04. The first program
# release is before the version 1, the second between the versions, the third after the version 2.
tab="$(printf '\t')"
printf '%s\n' "2026-11-01T09:00:00Z${tab}v1.2.1" "2026-11-03T09:00:00Z${tab}v1.2.2" \
    "2026-11-05T09:00:00Z${tab}v1.2.3" > "$work/answers/server-releases"
printf '2026-11-02T10:00:00Z\n' > "$work/answers/tag-1"
printf '2026-11-04T10:00:00Z\n' > "$work/answers/tag-2"
printf '2026-11-06T10:00:00Z\n' > "$work/answers/tag-3"

repo="$work/repo"
git init -q -b main "$repo"
git="git -C $repo -c user.name=tester -c user.email=tester@example.com -c commit.gpgsign=false"
merge() {
    $git checkout -q -b "pr-$1"
    $git commit -q --allow-empty -m "change $1"
    $git checkout -q main
    $git merge -q --no-ff -m "Merge pull request #$1 from owner/pr-$1" "pr-$1"
}
mkdir -p "$repo/programs/server"
printf 'name=splicefs-server\nprogram=x\nprograms=x\ndocs=x\nrelease_repo=example/server\n' \
    > "$repo/programs/server/program.conf"
$git add programs
$git commit -q -m "start"
first="$($git rev-parse HEAD)"
merge 4
fourth="$($git rev-parse HEAD)"
merge 5
tip="$($git rev-parse HEAD)"

# $1 name; $2 commit; then VARIABLE=value pairs for the environment. Leaves the status in
# "status", what it printed in "$work/out" and what gh was asked in "$work/answers/calls".
run() {
    commit="$2"
    shift 2
    : > "$work/answers/calls"
    rm -f "$work"/answers/notes-*
    status=0
    (cd "$repo" && env ANSWERS="$work/answers" PATH="$work/bin:$PATH" REPO=owner/repo \
        CHANGE_LOG_SCRIPT="$work/reader.sh" "$@" sh "$root/scripts/tag-release.sh" "$commit") \
        > "$work/out" 2>&1 || status=$?
}

# $1 case name, $2 the status wanted, $3 the calls wanted (one per line).
expect() {
    calls="$(cat "$work/answers/calls")"
    out="$(cat "$work/out")"
    if [ "$status" -eq "$2" ] && [ "$calls" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want %s "%s" got %s "%s" (%s)\n' "$1" "$2" "$3" "$status" "$calls" "$out"
        failed=$((failed + 1))
    fi
}

# $1 case name, $2 the release, $3 the notes wanted.
notes_are() {
    got="$(cat "$work/answers/notes-$2" 2>/dev/null)" || got=""
    if [ "$got" = "$3" ]; then printf 'ok   %s\n' "$1"; else
        printf 'FAIL %s: "%s"\n' "$1" "$got"
        failed=$((failed + 1))
    fi
}

run "the first version" "$tip"
expect "with no version tag the first is 1" 0 "tag 1 $tip
release 1"
notes_are "its notes hold every pull request so far" 1 "- Entry four.
- Entry five."

$git tag v0.4.20 "$first"
$git tag 1 "$fourth"
run "the next version" "$tip"
expect "the next is one more than the highest number, a v tag is not counted" 0 "tag 2 $tip
release 2"
notes_are "its notes hold the pull requests and the program releases since the previous number" 2 "- Entry five.
- Release of server v1.2.2.
- Release of server v1.2.3."

run "a commit that has a version already" "$fourth"
expect "a commit that already has a number is refused and nothing is made" 1 ""
grep -q 'already' "$work/out" || { echo "FAIL the refusal says why"; failed=$((failed + 1)); }

$git tag 2 "$tip"
run "a program release on a tagged commit" "$tip" PROGRAM_RELEASED=yes
expect "a program release gets a new number on a commit that has one" 0 "tag 3 $tip
release 3"
notes_are "its notes hold the program releases since the previous number, not the earlier ones" 3 "- Release of server v1.2.3."

# A dispatch whose line was lost to a newer one: the newer run tags once and has the line.
$git tag 3 "$tip"
run "a program release when none came since the previous number" "$tip" PROGRAM_RELEASED=yes
expect "it is tagged all the same, a number is the event" 0 "tag 4 $tip
release 4"
notes_are "its notes are empty" 4 ""
$git tag -d 3 >/dev/null

$git tag -d 2 >/dev/null
printf 'alice\nNo section.\n' > "$work/answers/pr-5"
run "a pull request without an entry" "$tip"
expect "no tag is made when the notes cannot be made" 1 ""

printf 'alice\n## Change log\n\n- Entry five.\n' > "$work/answers/pr-5"
run "a tag that cannot be created" "$tip" FAIL_TAG=1
expect "no release is made when the tag was not made" 1 ""

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "tag-release: all cases as expected"
