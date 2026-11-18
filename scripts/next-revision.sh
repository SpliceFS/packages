#!/bin/sh
# Prints the revision a build of a program version needs to be an upgrade of what is published:
# one more than the highest published revision of that version, and 0 when the version is not
# published yet. The published revisions are read from the apt index of the package site, which
# lists every version ever published, so nothing is counted anywhere else: the repository is the
# one record (scripts/published-lib.sh reads it).
# Usage: next-revision.sh PROGRAM VERSION     VERSION as the Makefile has it: v1.2.3, v1.2.3-rc.1
# Environment: PACKAGE_SITE (https://packages.splicefs.org) is the site; INDEX_FILE is a test
# hook that names a local index file and replaces the download.
set -eu

PROGRAM="${1:?usage: next-revision.sh PROGRAM VERSION}"
VERSION="${2:?usage: next-revision.sh PROGRAM VERSION}"
export PROGRAM
cd "$(dirname "$0")/.."
# The deb version of revision 0 is the version without a revision, which is what every published
# revision of this version starts with. The date only matters for a build with uncommitted
# changes, which is no release and is never asked about here.
REVISION=0
PACKAGE_DATE="$(date +%Y%m%d)"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
# shellcheck source=published-lib.sh
. scripts/published-lib.sh

index="$(mktemp)"
trap 'rm -f "$index"' EXIT
fetch_apt_index "$index"

# A version of this release is the version alone (revision 0) or the version, a hyphen and a whole
# number (the revision); another version of the program is not counted.
published_debvers "$index" | awk -v base="$debver" '
    {
        if ($1 == base) {
            revision = 0
        } else if (index($1, base "-") == 1 && substr($1, length(base) + 2) ~ /^[0-9]+$/) {
            revision = substr($1, length(base) + 2) + 0
        } else {
            next
        }
        if (!found || revision > highest) highest = revision
        found = 1
    }
    END { print found ? highest + 1 : 0 }
'
