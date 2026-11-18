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

# The stand-in answers the pull request lookups from files and records the other calls in
# "calls": the tag as "tag NAME SHA", the release as "release NAME" and its notes in notes-NAME.
# FAIL_TAG makes the creation of the tag fail, as it does when the name is already taken.
cat > "$work/bin/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
    "api repos/owner/repo/pulls/"*)
        cat "$ANSWERS/pr-${2##*/}" ;;
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

repo="$work/repo"
git init -q -b main "$repo"
git="git -C $repo -c user.name=tester -c user.email=tester@example.com -c commit.gpgsign=false"
merge() {
    $git checkout -q -b "pr-$1"
    $git commit -q --allow-empty -m "change $1"
    $git checkout -q main
    $git merge -q --no-ff -m "Merge pull request #$1 from owner/pr-$1" "pr-$1"
}
$git commit -q --allow-empty -m "start"
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
notes_are "its notes hold only the pull requests since the previous number" 2 "- Entry five."

run "a commit that has a version already" "$fourth"
expect "a commit that already has a number is refused and nothing is made" 1 ""
grep -q 'already' "$work/out" || { echo "FAIL the refusal says why"; failed=$((failed + 1)); }

$git tag 2 "$tip"
run "a program release on a tagged commit" "$tip" PROGRAM=server PROGRAM_TAG=v1.2.3
expect "a program release gets a new number on a commit that has one" 0 "tag 3 $tip
release 3"
notes_are "its notes name the program release" 3 "- Release of server v1.2.3."

for bad in "PROGRAM=ser/ver PROGRAM_TAG=v1.2.3" "PROGRAM=server PROGRAM_TAG=main" "PROGRAM=server PROGRAM_TAG="; do
    # shellcheck disable=SC2086 # the pair is split into the two assignments on purpose
    run "a program release that names no real release" "$tip" $bad
    expect "a program release with \"$bad\" is refused and nothing is made" 1 ""
done

$git tag -d 2 >/dev/null
printf 'alice\nNo section.\n' > "$work/answers/pr-5"
run "a pull request without an entry" "$tip"
expect "no tag is made when the notes cannot be made" 1 ""

printf 'alice\n## Change log\n\n- Entry five.\n' > "$work/answers/pr-5"
run "a tag that cannot be created" "$tip" FAIL_TAG=1
expect "no release is made when the tag was not made" 1 ""

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "tag-release: all cases as expected"
