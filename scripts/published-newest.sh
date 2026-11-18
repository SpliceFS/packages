#!/bin/sh
# Prints the version of the newest package of the program PROGRAM on the package site, as the apt
# index of the site writes it (1.2.3 for the release, 1.2.3-N for a later revision of it), or the
# word none when the program has no package there yet (an empty answer is never given, so it can
# only mean that the site was not read). It is what the upgrade tests start from: what
# people have installed is what the site serves, and a release on GitHub that is not published yet
# is not it. A run reads it once and records it in the version record (make packages
# UPGRADE_FROM=...), so that every job of the run starts from the same package, and none of them
# asks the site again, also when it answered none.
# Usage: published-newest.sh PROGRAM
# Environment: PACKAGE_SITE (https://packages.splicefs.org) is the site; INDEX_FILE is a test
# hook that names a local index file and replaces the download.
set -eu

PROGRAM="${1:?usage: published-newest.sh PROGRAM}"
export PROGRAM
cd "$(dirname "$0")/.."
# shellcheck source=program-conf.sh
. scripts/program-conf.sh
# shellcheck source=published-lib.sh
. scripts/published-lib.sh

index="$(mktemp)"
trap 'rm -f "$index"' EXIT
fetch_apt_index "$index"
newest="$(published_debvers "$index" | newest_debver)"
echo "${newest:-$nothing_published}"
