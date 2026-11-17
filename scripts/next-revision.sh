#!/bin/sh
# Prints the revision a build of a program version needs to be an upgrade of what is published:
# one more than the highest published revision of that version, and 0 when the version is not
# published yet. The published revisions are read from the apt index of the package site, which
# lists every version ever published, so nothing is counted anywhere else: the repository is the
# one record. A revision is the same in every format (scripts/package-lib.sh), so one format is
# enough to read it from.
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

index="$(mktemp)"
trap 'rm -f "$index"' EXIT
if [ -n "${INDEX_FILE:-}" ]; then
    cp "$INDEX_FILE" "$index" 2>/dev/null || fail "could not read the index $INDEX_FILE"
else
    url="${PACKAGE_SITE:-https://packages.splicefs.org}/$PROGRAM/apt/dists/stable/main/binary-amd64/Packages"
    # A failed download must never read as "nothing is published": the packages would then be
    # built as revision 0 over a published one.
    curl -fsSL --proto =https --proto-redir =https --retry 3 -o "$index" "$url" || fail "could not read $url"
fi

# A stanza of the index names its package and its version. A version of this release is the
# version alone (revision 0) or the version, a hyphen and a whole number (the revision).
awk -v name="$name" -v base="$debver" '
    $1 == "Package:" { package = $2 }
    $1 == "Version:" && package == name {
        if ($2 == base) {
            revision = 0
        } else if (index($2, base "-") == 1 && substr($2, length(base) + 2) ~ /^[0-9]+$/) {
            revision = substr($2, length(base) + 2) + 0
        } else {
            next
        }
        if (!found || revision > highest) highest = revision
        found = 1
    }
    END { print found ? highest + 1 : 0 }
' "$index"
