#!/bin/sh
# Says whether the packages of a release of a program are already on the package site: prints
# "published" when the apt index of the site lists the deb version of the release, and "new" when
# it does not. A package is published only for a new release of its program, so a release that is
# published is never built again. The index lists every version ever published, so nothing is
# counted anywhere else: the site is the one record (scripts/published-lib.sh reads it). A site
# that cannot be read ends the script with a message and no answer: that must never read as "new".
# Usage: release-published.sh PROGRAM TAG     TAG as the release has it: v1.2.3, v1.2.3-rc.1
# Environment: PACKAGE_SITE (https://packages.splicefs.org) is the site; INDEX_FILE is a test
# hook that names a local index file and replaces the download.
set -eu

PROGRAM="${1:?usage: release-published.sh PROGRAM TAG}"
VERSION="${2:?usage: release-published.sh PROGRAM TAG}"
export PROGRAM
cd "$(dirname "$0")/.."
# The date only matters for a build with uncommitted changes, which is no release and is never
# asked about here.
PACKAGE_DATE="$(date +%Y%m%d)"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
# shellcheck source=published-lib.sh
. scripts/published-lib.sh

index="$(mktemp)"
trap 'rm -f "$index"' EXIT
fetch_apt_index "$index"

published="$(published_debvers "$index")"
if printf '%s\n' "$published" | grep -Fxq -- "$debver"; then
    echo published
else
    echo new
fi
