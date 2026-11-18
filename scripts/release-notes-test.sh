#!/bin/sh
# Test of scripts/release-notes.sh: the notes of a release are the change log entries of the
# pull requests merged since the previous version tag. Runs on the host, no network (part of make
# check): the repository is a throwaway one, gh is a stand-in that answers from files, and the
# reader of a description is a stand-in with the contract of the shared one.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
mkdir "$work/bin" "$work/answers"

# The answer of the API for a pull request is two things: the login of the author, then the
# description. The stand-in prints the file of that pull request and records what was asked.
cat > "$work/bin/gh" <<'GH'
#!/bin/sh
[ "$1" = api ] || exit 2
printf '%s\n' "$2" >> "$ANSWERS/asked"
n="${2##*/}"
cat "$ANSWERS/pr-$n"
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
$git commit -q --allow-empty -m "start"
merge 4
$git tag 1
$git commit -q --allow-empty -m "a commit pushed straight to main"
merge 5
$git commit -q --allow-empty -m "Merge branch 'main' into somewhere"
merge 6
$git tag 2
merge 7

# $1 case name, $2 previous tag (may be empty), $3 the commit, $4 status wanted, $5 output wanted.
notes() {
    status=0
    got="$(cd "$repo" && ANSWERS="$work/answers" PATH="$work/bin:$PATH" REPO=owner/repo \
        CHANGE_LOG_SCRIPT="$work/reader.sh" sh "$root/scripts/release-notes.sh" "$2" "$3" 2>"$work/err")" || status=$?
    if [ "$status" -eq "$4" ] && [ "$got" = "$5" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want %s "%s" got %s "%s"\n' "$1" "$4" "$5" "$status" "$got"
        failed=$((failed + 1))
    fi
}

notes "the pull requests after the previous tag, oldest first, and no earlier one" 1 2 0 "- Entry five.
- Entry five, second line.
- Internal: a dependency is updated. Nothing changes for users."
notes "without a previous tag every pull request counts" "" 2 0 "- Entry four.
- Entry five.
- Entry five, second line.
- Internal: a dependency is updated. Nothing changes for users."
notes "nothing merged since the previous tag, no notes" 2 2 0 ""
: > "$work/answers/asked"
notes "the pull request that has no change log section stops the notes" 2 main 1 ""
if grep -q '#7' "$work/err"; then echo "ok   the failure names the pull request"; else
    echo "FAIL the failure names the pull request: $(cat "$work/err")"
    failed=$((failed + 1))
fi
if [ "$(cat "$work/answers/asked")" = "repos/owner/repo/pulls/7" ]; then
    echo "ok   only the pull requests of the range are asked for"
else
    echo "FAIL only the pull requests of the range are asked for: $(cat "$work/answers/asked")"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "release-notes: all cases as expected"
