#!/bin/sh
# check: workflows: a called workflow runs the code of its own commit, never a ref the caller names
# Test of the checkouts of the workflows (part of make check). A workflow that another
# repository calls must run the code of its own commit, never the code a caller names: an input
# that chooses the ref of a checkout lets a caller choose what runs here, with this repository's
# token and caches. So no checkout takes its repository or ref straight from an input, and a called
# workflow checks this repository out at job.workflow_sha, the commit of the workflow file that
# defines the job, of the repository job.workflow_repository. The check runs on the real
# workflows and on small workflows that break each rule.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
failed=0

# $1 a folder of workflow files. Prints one line for each checkout that breaks a rule.
violations() {
    grep -n -E '^[[:space:]]*(ref|repository):[[:space:]]*\$\{\{[[:space:]]*inputs\.' "$1"/*.yml | sed 's/$/  (repository or ref from an input)/' || true
    grep -n -E 'packages-ref' "$1"/*.yml | sed 's/$/  (the ref of this repository is not an input)/' || true
    grep -n -E '^[[:space:]]*repository:[[:space:]]*SpliceFS/packages' "$1"/*.yml | sed 's/$/  (name the repository job.workflow_repository, next to its commit)/' || true
    awk '
        FNR == 1 { pending = 0 }
        pending && $0 !~ /^[ \t]*ref:[ \t]*\$\{\{ job\.workflow_sha \}\}[ \t]*$/ {
            print FILENAME ":" FNR ": the ref after job.workflow_repository is not job.workflow_sha"
        }
        { pending = ($0 ~ /repository:[ \t]*\$\{\{ job\.workflow_repository \}\}/) }
    ' "$1"/*.yml
}

# $1 case name, $2 how many violation lines the folder $3 must show.
check() {
    got="$(violations "$3" | wc -l | tr -d ' ')"
    if [ "$got" -ne "$2" ]; then
        printf 'FAIL %s: %s violation(s), wanted %s\n' "$1" "$got" "$2"
        violations "$3" | sed 's/^/     /'
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

# The expressions of a workflow are text here, not shell expansions.
# shellcheck disable=SC2016
{
    own_repo='${{ job.workflow_repository }}'
    own_sha='${{ job.workflow_sha }}'
    input_ref='${{ inputs.ref }}'
    input_repo='${{ inputs.repository }}'
}

# $1 the folder, $2 the repository line and $3 the ref line of a checkout step.
workflow() {
    mkdir -p "$1"
    printf 'steps:\n  - uses: actions/checkout@x\n    with:\n      repository: %s\n      ref: %s\n' "$2" "$3" > "$1/a.yml"
}

check "the workflows of this repository" 0 "$root/.github/workflows"

workflow "$tree/good" "$own_repo" "$own_sha"
check "a checkout at the commit of the called workflow" 0 "$tree/good"

workflow "$tree/ref-input" "$own_repo" "$input_ref"
check "a ref from an input breaks both rules about it" 2 "$tree/ref-input"

workflow "$tree/repo-input" "$input_repo" "$own_sha"
check "a repository from an input" 1 "$tree/repo-input"

workflow "$tree/branch" "$own_repo" main
check "a branch where the commit of the workflow belongs" 1 "$tree/branch"

workflow "$tree/named" SpliceFS/packages "$own_sha"
check "the repository named, not paired with the commit" 1 "$tree/named"

mkdir -p "$tree/input-name"
printf 'on:\n  workflow_call:\n    inputs:\n      packages-ref:\n        type: string\n' > "$tree/input-name/a.yml"
check "an input for the ref of this repository" 1 "$tree/input-name"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "workflow checkout checks done"
