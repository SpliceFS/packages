#!/bin/sh
# Test of scripts/change-log-entry.sh: the change log entry of a pull request, with the default
# entry for the dependency bot only. Runs on the host, no network (part of make check). The reader
# of a description is a stand-in with the same contract as the shared one: entries on standard
# output, or an error and status 1 when the section is missing, with DEFAULT_ENTRY as the entry
# when that is set.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

cat > "$work/reader.sh" <<'READER'
#!/bin/sh
body="$(cat)"
if printf '%s\n' "$body" | grep -q '^## Change log'; then
    printf '%s\n' "$body" | grep '^- '
elif [ -n "${DEFAULT_ENTRY:-}" ]; then
    printf -- '- %s\n' "$DEFAULT_ENTRY"
else
    echo "change_log: missing" >&2
    exit 1
fi
READER

# $1 case name, $2 author login, $3 description, $4 status wanted, $5 output wanted.
entry() {
    status=0
    got="$(printf '%s\n' "$3" | CHANGE_LOG_SCRIPT="$work/reader.sh" sh scripts/change-log-entry.sh "$2" 2>/dev/null)" || status=$?
    if [ "$status" -eq "$4" ] && [ "$got" = "$5" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want %s "%s" got %s "%s"\n' "$1" "$4" "$5" "$status" "$got"
        failed=$((failed + 1))
    fi
}

entry "a person's entry is read from the description" alice "## Change log

- Fixed a thing." 0 "- Fixed a thing."
entry "a person without the section is refused" alice "Nothing here." 1 ""
entry "the dependency bot without the section gets the default entry" 'dependabot[bot]' "Bumps a thing." 0 \
    "- Internal: a dependency is updated. Nothing changes for users."
entry "the dependency bot with a section keeps its own entry" 'dependabot[bot]' "## Change log

- Own entry." 0 "- Own entry."
entry "a look-alike of the bot gets no default" 'dependabot-fan' "Bumps a thing." 1 ""

status=0
CHANGE_LOG_SCRIPT='' sh scripts/change-log-entry.sh alice </dev/null >/dev/null 2>&1 || status=$?
if [ "$status" -ne 0 ]; then echo "ok   a missing reader is an error"; else
    echo "FAIL a missing reader is an error"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "change-log-entry: all cases as expected"
