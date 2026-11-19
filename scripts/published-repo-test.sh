#!/bin/sh
# check: published-repo.sh: the published repository of a program carried from the job that fetches it to the others
# Tests scripts/published-repo.sh, which carries the published repository of a program, as
# make program-fetch downloaded it, from the one job of a publish that downloads it to the jobs
# that build on it. Runs on the host, no Docker, no rsync (part of make check). The repository
# is a small hand-made folder.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
# Runs the command in a subshell, with its output in $work/output, and fails unless its status
# is $1 and its output contains $2. An empty text is no condition on the output.
expect() {
    want_status="$1"
    want_text="$2"
    shift 2
    status=0
    ("$@") >"$work/output" 2>&1 || status=$?
    [ "$status" -eq "$want_status" ] ||
        { cat "$work/output" >&2; fail "[$*] ended with status $status, want $want_status"; }
    [ -z "$want_text" ] || grep -qF -- "$want_text" "$work/output" ||
        { cat "$work/output" >&2; fail "[$*] did not say [$want_text]"; }
}

cd "$root"
pack() { scripts/published-repo.sh pack "$1"; }
unpack() { scripts/published-repo.sh unpack "$1"; }

# A published repository as the fetch leaves it: every format, a FreeBSD folder with colons in
# its name, an empty file and a file that is not world readable.
make_repo() {
    rm -rf "$1"
    mkdir -p "$1/repo/apt/dists/stable" "$1/repo/freebsd/FreeBSD:15:amd64/All" "$1/repo/alpine/x86_64"
    echo "release" >"$1/repo/apt/dists/stable/InRelease"
    echo "catalog" >"$1/repo/freebsd/FreeBSD:15:amd64/meta.conf"
    echo "package" >"$1/repo/freebsd/FreeBSD:15:amd64/All/splicefs-server-1.pkg"
    : >"$1/repo/alpine/x86_64/APKINDEX.tar.gz"
    chmod 640 "$1/repo/apt/dists/stable/InRelease"
}

# --- pack and unpack ------------------------------------------------------------------------

# What is unpacked is what was packed, folder names with colons and file modes included.
make_repo "$work/fetched"
expect 0 "packed" pack "$work/fetched"
[ -f "$work/fetched/published-repo.tar" ] || fail "pack wrote no published-repo.tar"
mkdir "$work/job"
cp "$work/fetched/published-repo.tar" "$work/job/"
expect 0 "unpacked" unpack "$work/job"
diff -r "$work/fetched/repo" "$work/job/repo" >/dev/null || fail "the unpacked repository differs from the packed one"
find "$work/job/repo/apt/dists/stable/InRelease" -perm 640 | grep -q . ||
    fail "a file mode did not survive the tar"

# The repository is the published one and nothing else: what the tests built there is gone.
echo "this version only" >"$work/job/repo/apt/dists/stable/Release"
expect 0 "unpacked" unpack "$work/job"
[ ! -e "$work/job/repo/apt/dists/stable/Release" ] || fail "unpack kept a file that is not in the tar"
diff -r "$work/fetched/repo" "$work/job/repo" >/dev/null || fail "the second unpack differs from the packed repository"

# A release that is not published yet has an empty repository, and that is no failure.
mkdir -p "$work/first/repo"
expect 0 "packed" pack "$work/first"
mkdir "$work/first-job"
cp "$work/first/published-repo.tar" "$work/first-job/"
expect 0 "unpacked" unpack "$work/first-job"
[ -d "$work/first-job/repo" ] || fail "an empty published repository did not unpack to a folder"
find "$work/first-job/repo" -mindepth 1 | grep -q . &&
    fail "an empty published repository unpacked to files"

# --- refusals -------------------------------------------------------------------------------

# Nothing was fetched: a tar of nothing must not look like an empty published repository.
mkdir "$work/nothing"
expect 1 "no repository folder" pack "$work/nothing"
[ ! -e "$work/nothing/published-repo.tar" ] || fail "pack wrote a tar without a repository"

# A missing tar stops before the repository is touched.
make_repo "$work/no-tar"
expect 1 "published-repo.tar is missing" unpack "$work/no-tar"
diff -r "$work/fetched/repo" "$work/no-tar/repo" >/dev/null || fail "a failed unpack changed the repository"

expect 1 "is not a folder" pack "$work/missing"
expect 2 "usage: published-repo.sh" pack ""
expect 2 "usage: published-repo.sh" unpack ""
expect 2 "usage: published-repo.sh" scripts/published-repo.sh other "$work"

echo "published-repo: all cases as expected"
