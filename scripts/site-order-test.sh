#!/bin/sh
# Proves from the text of the workflows that the run of a number tag talks to the package site
# exactly twice, and never in two jobs at once. The upload key of this repository reaches the
# whole site under one lock, so a second rsync session fails with "Another instance of rrsync
# is already accessing this directory", whichever folder it is for. Jobs run side by side unless
# `needs` orders them, and jobs of two workflows never are, so the order is read from `needs`,
# not from timing. The run of a tag is every workflow that a pushed tag starts, with the jobs of
# the local workflows they call:
#   - exactly one job reads the site (make program-fetch) and exactly one writes it (make
#     program-publish, make publish); no other job talks to it (rsync or the scripts behind it);
#   - neither of them is a matrix or inside a matrix call, whose copies run at the same time;
#   - the writing job comes after the reading one, and every other job of the run is ordered
#     with it: one needs the other, directly or not. Jobs that never talk to the site may run
#     alongside the reading one.
# The check reads the subset of YAML the workflows use: a job is a key two spaces in, its keys
# four spaces in, and `needs` is written on one line.
# It runs on the host, no Docker (part of make check). Usage: site-order-test.sh [WORKFLOW_DIR];
# the default is .github/workflows, and the checks are proven on small workflows of their own
# first.
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

# Reads one workflow and prints its facts, one per line, each job named PREFIX plus its key:
#   tag                 the workflow is started by a pushed tag
#   job ID | need ID DEP | matrix ID | fetch ID | write ID | talk ID
#   call ID FILE        the job runs the local workflow FILE
#   broken TEXT         a rule of the subset above is broken
parse_awk="$work/parse.awk"
cat >"$parse_awk" <<'AWK'
    /^on:[ ]*$/ { in_on = 1; next }
    /^  push:[ ]*$/ && in_on { in_push = 1; next }
    /^  [^ ]/ && in_on { in_push = 0 }
    /^    tags:/ && in_push { print "tag" }
    /^jobs:[ ]*$/ { in_jobs = 1; next }
    /^[^ #]/ { in_on = 0; in_push = 0; in_jobs = 0 }
    !in_jobs || /^[ ]*#/ { next }
    /^  [A-Za-z0-9_-]+:[ ]*$/ { job = prefix $1; sub(/:$/, "", job); print "job", job; next }
    job == "" { next }
    /^    needs:/ {
        list = $0
        sub(/^    needs:[ ]*/, "", list)
        gsub(/[][,]/, " ", list)
        if (list ~ /^[ ]*$/) print "broken", job ": needs must be written on one line"
        n = split(list, word, " ")
        for (i = 1; i <= n; i++) print "need", job, prefix word[i]
        next
    }
    /^    strategy:/ { print "matrix", job }
    /^    uses: \.\/\.github\/workflows\// { file = $2; sub(/.*\//, "", file); print "call", job, file }
    /program-fetch|publish-program[.]sh fetch/ { print "fetch", job }
    /program-publish([ ]|$)|make publish([ ]|$)|publish[.]sh send|publish-program[.]sh send/ { print "write", job }
    /program-fetch|program-publish|publish-program[.]sh|publish[.]sh|rsync/ { print "talk", job }
AWK

# The facts of the run of a tag, from the workflows in $1: those a tag starts, and inside each
# job that calls a local workflow, the jobs of that workflow, at any depth. They wait for what
# the calling job waits for, they are copies of a matrix when it is one, and a job that needs
# the calling job waits for all of them. The calls are taken from a queue, one after another, so
# that a call inside a call needs no recursion; a call is the one before its jobs in the queue.
run_facts() {
    dir="$1"
    queue="$work/queue"
    all="$work/all"
    : >"$queue"
    : >"$all"
    for file in "$dir"/*.yml; do
        name="$(basename "$file" .yml)"
        awk -v prefix="$name:" -f "$parse_awk" "$file" | grep -qx tag && echo "$name: $name.yml -" >>"$queue"
    done
    n=1
    while entry="$(sed -n "${n}p" "$queue")" && [ -n "$entry" ]; do
        n=$((n + 1))
        prefix="${entry%% *}"
        # GitHub runs calls four deep at most, so a deeper one is a circle.
        case "$prefix" in
            */*/*/*/*/*) echo "broken the calls of local workflows go round in a circle"; break ;;
            *) ;;
        esac
        caller="${entry##* }"
        called="${entry#"$prefix" }"
        called="${called%" $caller"}"
        [ -f "$dir/$called" ] || { echo "broken $caller calls $called, which is not in $dir"; continue; }
        awk -v prefix="$prefix" -f "$parse_awk" "$dir/$called" | grep -vx tag >"$work/facts"
        if [ "$caller" != - ]; then
            awk -v caller="$caller" '($1 == "need" || $1 == "matrix") && $2 == caller' "$all" >"$work/caller"
            awk '$1 == "job" { print $2 }' "$work/facts" | while read -r inner; do
                echo "need $caller $inner"
                awk -v inner="$inner" '{ $2 = inner; print }' "$work/caller"
            done >"$work/inherited"
            cat "$work/inherited" >>"$work/facts"
        fi
        cat "$work/facts" >>"$all"
        awk '$1 == "call" { print $2 "/", $3, $2 }' "$work/facts" >>"$queue"
    done
    cat "$all"
}

# The check of the facts: it prints one line for each rule the run breaks and exits 1 when there
# is one.
order_awk="$work/order.awk"
cat >"$order_awk" <<'AWK'
    function broken(text) { print text; bad = 1 }
    function list(set, text, j) { text = ""; for (j = 1; j <= count; j++) if (set[names[j]]) text = text " " names[j]; return text }
    $1 == "broken" { sub(/^broken /, ""); broken($0) }
    $1 == "job" { names[++count] = $2 }
    $1 == "need" { after[$2, $3] = 1 }
    $1 == "matrix" { matrix[$2] = 1 }
    $1 == "fetch" { fetches[$2] = 1 }
    $1 == "write" { writes[$2] = 1 }
    $1 == "talk" { talks[$2] = 1 }
    END {
        # Whom a job waits for, directly or through the jobs it needs.
        for (k = 1; k <= count; k++) for (a = 1; a <= count; a++) if (after[names[a], names[k]])
            for (b = 1; b <= count; b++) if (after[names[k], names[b]]) after[names[a], names[b]] = 1
        reading = list(fetches)
        writing = list(writes)
        if (split(reading, r, " ") != 1) broken("the run of a tag must read the site in exactly one job, not in:" reading)
        if (split(writing, w, " ") != 1) broken("the run of a tag must write the site in exactly one job, not in:" writing)
        for (a = 1; a <= count; a++) {
            job = names[a]
            if (talks[job] && !fetches[job] && !writes[job])
                broken(job " talks to the site and is neither the job that reads it nor the one that writes it")
            if (talks[job] && matrix[job])
                broken(job " talks to the site and is a matrix, so its copies run at once")
        }
        if (bad) exit 1
        for (a = 1; a <= count; a++) {
            job = names[a]
            if (job != w[1] && !after[job, w[1]] && !after[w[1], job])
                broken(job " and " w[1] " can run at once: neither needs the other")
        }
        if (!after[w[1], r[1]]) broken(w[1] " writes the site and does not come after " r[1] ", which reads it")
        exit bad
    }
AWK

# Fails with the message $1 after showing what the check said.
fail_with_verdict() {
    cat "$work/verdict" >&2
    fail "$1"
}

# Runs the check on the workflows in the folder $1. What it printed is in $work/verdict and its
# status in $verdict_status; this function itself never fails.
run_check() {
    verdict_status=0
    run_facts "$1" >"$work/run-facts"
    awk -f "$order_awk" "$work/run-facts" >"$work/verdict" || verdict_status=$?
}

# A run of two workflows that a tag starts, and one that it does not. The tag workflow reads
# the site, calls a workflow for each program in a matrix, and writes the site after all of
# them; the other one only tells someone.
good="$work/good"
mkdir -p "$good"
cat >"$good/run.yml" <<'EOF'
name: Example
on:
  push:
    tags: ["[0-9]*"]
jobs:
  plan:
    runs-on: ubuntu-latest
  fetch:
    needs: plan
    steps:
      - run: make program-fetch PROGRAM="$PROGRAM"
  program:
    needs: [plan, fetch]
    strategy:
      matrix:
        program: [a, b]
    uses: ./.github/workflows/one.yml
  send:
    needs: [plan, fetch, program]
    runs-on: sender
    steps:
      # make program-fetch in a comment is no job that reads
      - run: make program-publish PROGRAM="$PROGRAM"
      - run: make publish
  after:
    needs: send
    runs-on: ubuntu-latest
EOF
cat >"$good/one.yml" <<'EOF'
name: One
on: workflow_call
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: make build
  test:
    needs: build
    runs-on: ubuntu-latest
EOF
cat >"$good/notify.yml" <<'EOF'
name: Notify
on:
  push:
    branches: [main]
jobs:
  tell:
    steps:
      - run: rsync -a a b
EOF

# Runs the check on a copy of the good run whose file $3 (run.yml unless given) is changed by
# the sed script $2, and fails unless it says $1, or says nothing and passes when $1 is empty.
case_with() {
    expected="$1"
    rm -rf "$work/case"
    cp -R "$good" "$work/case"
    sed -e "$2" "$good/${3:-run.yml}" >"$work/case/${3:-run.yml}"
    run_check "$work/case"
    if [ -z "$expected" ]; then
        [ "$verdict_status" -eq 0 ] || fail_with_verdict "[$2] was refused"
    else
        grep -qF -- "$expected" "$work/verdict" || fail_with_verdict "[$2] did not say [$expected]"
    fi
}

run_check "$good"
[ "$verdict_status" -eq 0 ] || fail_with_verdict "the good example was refused"
# A job inside a matrix call that reads: every program would read at once.
case_with "program/build talks to the site and is a matrix" \
    's|make build|make program-fetch|' one.yml
# Two jobs that read, even ordered.
case_with "must read the site in exactly one job, not in: run:fetch run:program/build" \
    's|make build|make program-fetch|' one.yml
# A second workflow of the tag that writes the site runs alongside the first.
case_with "must write the site in exactly one job, not in: notify:site run:send" \
    's|branches: \[main\]|tags: ["[0-9]*"]|; s|tell:|site:|; s|rsync -a a b|make publish|' notify.yml
# A job of the run that talks to the site but neither reads nor writes it as the run does.
case_with "notify:tell talks to the site and is neither" \
    's|branches: \[main\]|tags: ["[0-9]*"]|' notify.yml
# A job of a tag workflow that no `needs` orders with the writing job.
case_with "notify:tell and run:send can run at once" \
    's|branches: \[main\]|tags: ["[0-9]*"]|; s|rsync -a a b|make build|' notify.yml
# The writing job must wait for every program call, and through it for the jobs inside.
case_with "run:program/test and run:send can run at once" \
    's|needs: \[plan, fetch, program\]|needs: [plan, fetch]|'
# A job inside the call waits for what the calling job needs, so it comes after the reading job.
case_with "" \
    's|needs: \[plan, fetch, program\]|needs: program|'
# A job that does not talk to the site may run alongside the reading job.
case_with "" \
    's|needs: \[plan, fetch\]|needs: plan|; s|needs: \[plan, fetch, program\]|needs: [fetch, program]|'
case_with "run:send writes the site and does not come after run:fetch" \
    's|needs: plan|needs: [plan, send]|; s|needs: \[plan, fetch, program\]|needs: [plan, program]|; s|needs: \[plan, fetch\]|needs: plan|'
case_with "the run of a tag must read the site in exactly one job, not in:" \
    's|make program-fetch|make something|'
case_with "needs must be written on one line" \
    's|needs: plan|needs:|'
# A call inside a call is read too, and the matrix of the first call reaches its jobs.
case_with "run:program/test/fetch talks to the site and is a matrix" \
    '/^  test:/,/^$/s|    runs-on: ubuntu-latest|    uses: ./.github/workflows/run.yml|' one.yml

workflows="${1:-.github/workflows}"
run_check "$workflows"
[ "$verdict_status" -eq 0 ] || fail_with_verdict "the run of a tag in $workflows breaks a rule"
echo "site-order: all cases as expected, and the run of a tag in $workflows reads the site once and writes it once, ordered with every other job"
