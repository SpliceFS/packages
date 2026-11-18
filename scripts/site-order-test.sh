#!/bin/sh
# Proves from the text of the publish workflow that no two jobs open an rsync session to the
# package site at once. The site lets one session at a time into a folder, and a second one
# fails with "Another instance of rrsync is already accessing this directory". Jobs of a
# workflow run side by side unless `needs` orders them, so the order is read from `needs`, not
# from timing:
#   - the published repository is fetched (make program-fetch) in exactly one job;
#   - no job that talks to the site is a matrix, whose copies run at the same time;
#   - every two jobs that talk to the site are ordered, one needs the other, directly or not.
# The check reads the subset of YAML the workflows use: a job is a key two spaces in, its keys
# four spaces in, and `needs` is written on one line. It runs on the host, no Docker (part of
# make check). Usage: site-order-test.sh [WORKFLOW_FILE]; the default is the publish workflow,
# and the checks are proven on small workflows of their own first.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The check, in awk: it prints one line for each rule the workflow breaks and exits 1 when there
# is one. What talks to the site: the Makefile targets that run rsync and the scripts behind them.
order_awk="$work/order.awk"
cat >"$order_awk" <<'AWK'
    function broken(text) { print text; bad = 1 }
    /^jobs:[ ]*$/ { in_jobs = 1; next }
    /^[^ #]/ { in_jobs = 0 }
    !in_jobs || /^[ ]*#/ { next }
    /^  [A-Za-z0-9_-]+:[ ]*$/ { job = $1; sub(/:$/, "", job); names[++count] = job; next }
    job == "" { next }
    /^    needs:/ {
        list = $0
        sub(/^    needs:[ ]*/, "", list)
        gsub(/[][,]/, " ", list)
        if (list ~ /^[ ]*$/) broken(job ": needs must be written on one line")
        n = split(list, word, " ")
        for (i = 1; i <= n; i++) needs[job, word[i]] = 1
        next
    }
    /^    strategy:/ { matrix[job] = 1 }
    /program-fetch/ { fetches[job] = 1 }
    /program-fetch|program-publish|publish-program[.]sh|publish[.]sh|rsync/ { talks[job] = 1 }
    END {
        # Whom a job waits for, directly or through the jobs it needs, until nothing is added.
        for (a in names) for (b in names) if (needs[names[a], names[b]]) after[names[a], names[b]] = 1
        do {
            grew = 0
            for (a in names) for (b in names) for (c in names)
                if (after[names[a], names[b]] && after[names[b], names[c]] && !after[names[a], names[c]]) {
                    after[names[a], names[c]] = 1
                    grew = 1
                }
        } while (grew)
        fetching = ""
        for (a = 1; a <= count; a++) if (fetches[names[a]]) fetching = fetching " " names[a]
        if (fetching == "") broken("no job fetches the published repository")
        if (split(fetching, each, " ") > 1) broken("program-fetch runs in more than one job:" fetching)
        for (a = 1; a <= count; a++) {
            if (talks[names[a]] && matrix[names[a]])
                broken(names[a] " talks to the site and is a matrix, so its copies run at once")
            for (b = a + 1; b <= count; b++)
                if (talks[names[a]] && talks[names[b]] && !after[names[a], names[b]] && !after[names[b], names[a]])
                    broken(names[a] " and " names[b] " both talk to the site and neither needs the other")
        }
        exit bad
    }
AWK

# Fails with the message $1 after showing what the check said.
fail_with_verdict() {
    cat "$work/verdict" >&2
    fail "$1"
}

# Runs the check on the workflow $1. What it printed is in $work/verdict and its status in
# $verdict_status; this function itself never fails.
run_check() {
    verdict_status=0
    awk -f "$order_awk" "$1" >"$work/verdict" || verdict_status=$?
}

# A workflow of three jobs, to be changed by the cases below. fetch reads the site, build does
# not, send writes it after both.
good="$work/good.yml"
cat >"$good" <<'EOF'
name: Example
on: workflow_call
jobs:
  verify:
    runs-on: ubuntu-latest
  fetch:
    needs: verify
    steps:
      - run: make program-fetch PROGRAM="$PROGRAM"
  build:
    needs: [verify, fetch]
    strategy:
      matrix:
        release: [1, 2]
    steps:
      - run: make build
  send:
    needs: [verify, fetch, build]
    runs-on: sender
    steps:
      # make program-fetch in a comment is no job that fetches
      - run: make program-publish PROGRAM="$PROGRAM"
EOF

# Runs the check on a copy of the good workflow changed by the sed script $2 and fails unless
# it says $1, or says nothing and passes when $1 is empty.
case_with() {
    expected="$1"
    sed -e "$2" "$good" >"$work/case.yml"
    run_check "$work/case.yml"
    if [ -z "$expected" ]; then
        [ "$verdict_status" -eq 0 ] || fail_with_verdict "[$2] was refused"
    else
        grep -qF -- "$expected" "$work/verdict" || fail_with_verdict "[$2] did not say [$expected]"
    fi
}

run_check "$good"
[ "$verdict_status" -eq 0 ] || fail_with_verdict "the good example was refused"
# Two jobs that fetch, even ordered: the repository is fetched once and handed on.
case_with "program-fetch runs in more than one job: fetch build" \
    's|make build|make program-fetch|'
# A job that fetches and a job that sends, with nothing between them.
case_with "fetch and send both talk to the site and neither needs the other" \
    's|needs: \[verify, fetch, build\]|needs: [verify, build]|; s|needs: \[verify, fetch\]|needs: verify|'
# The order comes through the jobs between, not only from a direct line.
case_with "" \
    's|needs: \[verify, fetch, build\]|needs: build|'
# A matrix that talks to the site runs its copies at the same time, whatever they need.
case_with "send talks to the site and is a matrix" \
    's|runs-on: sender|strategy: {matrix: {release: [1, 2]}}|'
# Any rsync is a talk, not only the two targets.
case_with "build and send both talk to the site" \
    's|make build|rsync -a a b|; s|needs: \[verify, fetch\]|needs: [verify]|; s|needs: \[verify, fetch, build\]|needs: [verify, fetch]|'
case_with "no job fetches the published repository" \
    's|make program-fetch|make something|'
case_with "needs must be written on one line" \
    's|needs: verify|needs:|'

workflow="${1:-.github/workflows/publish-one-program.yml}"
run_check "$workflow"
[ "$verdict_status" -eq 0 ] || fail_with_verdict "$workflow breaks a rule"
echo "site-order: all cases as expected, and $workflow orders every job that talks to the site"
