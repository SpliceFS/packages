#!/bin/sh
# Carries the published repository of a program, as make program-fetch downloaded it into
# OUTPUT_DIR/repo, from the one job of a publish run that downloads it to the jobs that build on
# it. The package site lets one rsync session at a time into a folder, so a run opens one
# session to read it and hands the result on as a CI artifact. The upload of an artifact refuses
# the colons in the names of the FreeBSD folders, so one tar carries it. Runs on the host
# (make published-pack and make published-unpack).
# Usage: published-repo.sh pack OUTPUT_DIR | published-repo.sh unpack OUTPUT_DIR
#   pack    writes OUTPUT_DIR/published-repo.tar from OUTPUT_DIR/repo. An empty repository (a
#           program that is not published yet) is packed as it is.
#   unpack  makes OUTPUT_DIR/repo from OUTPUT_DIR/published-repo.tar and nothing else, so what
#           an earlier step left there, such as the repository of the tests, is gone. It stops
#           before it removes anything when the tar is missing.
set -eu

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mode="${1:-}"
dist="${2:-}"
case "$mode:$dist" in
    pack:?* | unpack:?*) ;;
    *)
        echo "usage: published-repo.sh pack OUTPUT_DIR | published-repo.sh unpack OUTPUT_DIR" >&2
        exit 2
        ;;
esac

pack() {
    [ -d "$dist/repo" ] || fail "no repository folder in $dist/repo, make program-fetch did not leave one"
    tar -cf "$tar_file" -C "$dist/repo" .
    echo "packed $dist/repo into $tar_file"
}

unpack() {
    [ -f "$tar_file" ] || fail "$tar_file is missing, the job that fetches the published repository did not leave it"
    rm -rf "$dist/repo"
    mkdir -p "$dist/repo"
    tar -xf "$tar_file" -C "$dist/repo"
    echo "unpacked $tar_file into $dist/repo"
}

# The tar has one absolute name, for both modes.
[ -d "$dist" ] || fail "$dist is not a folder"
tar_file="$(cd "$dist" && pwd)/published-repo.tar"
"$mode"
