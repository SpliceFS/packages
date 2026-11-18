#!/bin/sh
# Prints the change log entry of a pull request: reads its description on standard input and
# prints the entries of its "## Change log" section, one "- " line each. The pull request check
# and the notes of a release both read an entry here, so they can never disagree about what a
# description says.
#
#   change-log-entry.sh <login of the author>
#
# CHANGE_LOG_SCRIPT names the reader of a description, the shared change-log.sh of the rules
# repository, which a workflow checks out. The dependency bot cannot write the section, so its
# pull requests get a default entry; nobody else does.
set -eu

[ "$#" -eq 1 ] || { echo "usage: change-log-entry.sh <author login>" >&2; exit 2; }
login="$1"
[ -n "${CHANGE_LOG_SCRIPT:-}" ] || { echo "change-log-entry: CHANGE_LOG_SCRIPT is not set" >&2; exit 2; }

DEFAULT_ENTRY=""
if [ "$login" = 'dependabot[bot]' ]; then
    DEFAULT_ENTRY='Internal: a dependency is updated. Nothing changes for users.'
fi
export DEFAULT_ENTRY
sh "$CHANGE_LOG_SCRIPT"
