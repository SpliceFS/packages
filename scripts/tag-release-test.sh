#!/bin/sh
# check: tag-release.sh: the next number tag on a commit of main, and its release
# Test of scripts/tag-release.sh: the next version tag is put on a commit of main and a GitHub
# release is made for it, whose notes end with the cut time of the version. Runs on the host, no
# network (part of make check): the repository is a throwaway one, gh is a stand-in that records
# what it was asked to do and keeps the releases it made, and date is a stand-in clock.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
mkdir "$work/bin" "$work/answers"

# The stand-in answers the lookups of pull requests and of the program releases from files. It
# keeps the release it is asked to make as its notes in body-NAME, which is what a later run reads
# back from "the release of a version tag", and records the other calls in "calls": the tag as
# "tag NAME SHA", the release as "release NAME". FAIL_TAG makes the creation of the tag fail, as
# it does when the name is already taken. When the file "during" exists, its lines are program
# releases that are published while the release is being made: they are added to the program
# releases at that moment, which is after the notes were read.
cat > "$work/bin/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
    "api repos/owner/repo/pulls/"*)
        cat "$ANSWERS/pr-${2##*/}" ;;
    "api repos/owner/repo/releases/tags/"*)
        cat "$ANSWERS/body-${2##*/}" ;;
    "api repos/example/server/releases")
        cat "$ANSWERS/server-releases" ;;
    "api repos/owner/repo/git/refs")
        [ -z "${FAIL_TAG:-}" ] || exit 1
        echo "tag ${4#ref=refs/tags/} ${6#sha=}" >> "$ANSWERS/calls" ;;
    "release create")
        name="$3"
        echo "release $name" >> "$ANSWERS/calls"
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --notes-file ]; then cp "$2" "$ANSWERS/body-$name"; fi
            shift
        done
        if [ -f "$ANSWERS/during" ]; then cat "$ANSWERS/during" >> "$ANSWERS/server-releases"; fi ;;
    *) echo "unexpected: $*" >&2; exit 2 ;;
esac
GH
# The clock: each call prints and uses up the first line of "clock", and a call after the lines
# are gone fails, so a script that reads the time more often than the test planned is found.
cat > "$work/bin/date" <<'DATE'
#!/bin/sh
[ "$*" = "-u +%Y-%m-%dT%H:%M:%SZ" ] || { echo "unexpected: date $*" >&2; exit 2; }
now="$(sed -n 1p "$ANSWERS/clock")"
[ -n "$now" ] || exit 1
sed 1d "$ANSWERS/clock" > "$ANSWERS/clock.next"
mv "$ANSWERS/clock.next" "$ANSWERS/clock"
echo "$now"
DATE
chmod +x "$work/bin/gh" "$work/bin/date"
cat > "$work/reader.sh" <<'READER'
#!/bin/sh
grep '^- '
READER
printf 'alice\n## Change log\n\n- Entry four.\n' > "$work/answers/pr-4"
printf 'alice\n## Change log\n\n- Entry five.\n' > "$work/answers/pr-5"
# The program releases, told apart by their time. The versions are cut one after the other (see
# the clock of each run below): the first at 2026-11-02, the second at 2026-11-04. The first
# program release is before the version 1, the second between the versions, the third and the
# fourth are published while the version 2 is being made, one at the second of its cut time and
# one a second later, and the fifth is after the version 2.
tab="$(printf '\t')"
printf '%s\n' "2026-11-01T09:00:00Z${tab}v1.2.1" "2026-11-03T09:00:00Z${tab}v1.2.2" \
    "2026-11-05T09:00:00Z${tab}v1.2.5" > "$work/answers/server-releases"
printf '2026-11-04T10:00:00Z%sv1.2.3\n2026-11-04T10:00:01Z%sv1.2.4\n' "$tab" "$tab" > "$work/answers/late"
# The times of the next run (see run); each run that is not given any has this one.
default_times=2026-11-30T00:00:00Z
times="$default_times"
# $@ the times, in the order the script will read the clock.
clock_is() {
    times="$*"
}

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
# "status", what it printed in "$work/out", what gh was asked in "$work/answers/calls" and the
# times of the clock that were not read in "$work/answers/clock".
run() {
    commit="$2"
    shift 2
    : > "$work/answers/calls"
    : > "$work/answers/clock"
    for now in $times; do echo "$now" >> "$work/answers/clock"; done
    times="$default_times"
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
    got="$(cat "$work/answers/body-$2" 2>/dev/null)" || got=""
    if [ "$got" = "$3" ]; then printf 'ok   %s\n' "$1"; else
        printf 'FAIL %s: "%s"\n' "$1" "$got"
        failed=$((failed + 1))
    fi
}

clock_is 2026-11-02T10:00:00Z
run "the first version" "$tip"
expect "with no version tag the first is 1" 0 "tag 1 $tip
release 1"
notes_are "its notes hold every pull request so far and record its cut time" 1 "- Entry four.
- Entry five.
<!-- cut: 2026-11-02T10:00:00Z -->"

# The version 2 is made at 10:00:00 on 2026-11-04 (the time it is told it is) and two program
# releases are published while it is being made, after its notes were read: one in the second of
# its cut time, one a second later. A second reading of the clock would give a later time, which
# is how a cut time taken at the end instead of the start would lose them.
$git tag v0.4.20 "$first"
$git tag 1 "$fourth"
cp "$work/answers/late" "$work/answers/during"
clock_is 2026-11-04T10:00:00Z 2026-11-04T10:00:02Z
run "the next version" "$tip"
rm "$work/answers/during"
expect "the next is one more than the highest number, a v tag is not counted" 0 "tag 2 $tip
release 2"
notes_are "its notes hold the pull requests and the program releases from the previous cut up to its own, and its cut time" 2 "- Entry five.
- Release of server v1.2.2.
<!-- cut: 2026-11-04T10:00:00Z -->"
unread="$(cat "$work/answers/clock")"
if [ "$unread" = "2026-11-04T10:00:02Z" ]; then echo "ok   the clock is read once, before anything else"; else
    echo "FAIL the clock is read once, before anything else"
    failed=$((failed + 1))
fi

run "a commit that has a version already" "$fourth"
expect "a commit that already has a number is refused and nothing is made" 1 ""
grep -q 'already' "$work/out" || { echo "FAIL the refusal says why"; failed=$((failed + 1)); }

# The release published in the second of the cut of 2 and the one a second later are in the next
# version, and no release is in two versions.
$git tag 2 "$tip"
clock_is 2026-11-06T10:00:00Z
run "a program release on a tagged commit" "$tip" PROGRAM_RELEASED=yes
expect "a program release gets a new number on a commit that has one" 0 "tag 3 $tip
release 3"
notes_are "its notes hold what was published while the previous number was made, and the later release" 3 "- Release of server v1.2.3.
- Release of server v1.2.4.
- Release of server v1.2.5.
<!-- cut: 2026-11-06T10:00:00Z -->"
listed="$(cat "$work/answers/body-2" "$work/answers/body-3" | grep '^- Release of' | sort)"
if [ "$listed" = "$(printf '%s\n' '- Release of server v1.2.2.' '- Release of server v1.2.3.' \
    '- Release of server v1.2.4.' '- Release of server v1.2.5.')" ]; then
    echo "ok   every program release since the first number is in exactly one version"
else
    echo "FAIL every program release since the first number is in exactly one version: $listed"
    failed=$((failed + 1))
fi

# A dispatch whose line was lost to a newer one: the newer run tags once and has the line.
$git tag 3 "$tip"
clock_is 2026-11-07T10:00:00Z
run "a program release when none came since the previous number" "$tip" PROGRAM_RELEASED=yes
expect "it is tagged all the same, a number is the event" 0 "tag 4 $tip
release 4"
notes_are "its notes are only its cut time" 4 "<!-- cut: 2026-11-07T10:00:00Z -->"
$git tag -d 3 >/dev/null

$git tag -d 2 >/dev/null
printf 'alice\nNo section.\n' > "$work/answers/pr-5"
run "a pull request without an entry" "$tip"
expect "no tag is made when the notes cannot be made" 1 ""

printf 'alice\n## Change log\n\n- Entry five.\n' > "$work/answers/pr-5"
run "a tag that cannot be created" "$tip" FAIL_TAG=1
expect "no release is made when the tag was not made" 1 ""

printf 'Notes without a cut line.\n' > "$work/answers/body-1"
run "a previous release without a cut line" "$tip"
expect "nothing is made when the time of the previous version is not known" 1 ""
grep -q 'release 1 has no cut line' "$work/out" || { echo "FAIL the failure names the release"; failed=$((failed + 1)); }

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "tag-release: all cases as expected"
