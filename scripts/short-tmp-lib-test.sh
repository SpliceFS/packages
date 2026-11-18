#!/bin/sh
# Test of scripts/short-tmp-lib.sh (part of make check): the folder for gpg homes has a short path
# whatever TMPDIR says, and removing it stops the agent of every home in it first. Runs on the
# host, no Docker, no gpg: a stand-in gpgconf at the front of PATH records what it is asked.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
made=""
second=""
trap 'rm -rf "$work" "$made" "$second"' EXIT
failed=0

# $1 case name, then the command that must succeed.
expect() {
    name="$1"
    shift
    # The status of the command is the answer here, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if "$@"; then echo "ok   $name"; else
        echo "FAIL $name"
        failed=$((failed + 1))
    fi
}

long="$work/long-$(printf '%0120d' 0)"
mkdir "$work/bin" "$long"
cat > "$work/bin/gpgconf" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$GPGCONF_LOG"
STUB
chmod +x "$work/bin/gpgconf"
export GPGCONF_LOG="$work/gpgconf.log"
: > "$GPGCONF_LOG"

# shellcheck source=short-tmp-lib.sh
. "$root/scripts/short-tmp-lib.sh"

made="$(TMPDIR="$long" short_tmp_dir)"
second="$(short_tmp_dir)"

is_short() { [ "${#1}" -le 30 ]; }
is_private() {
    private="$(find "$1" -maxdepth 0 -perm 700)"
    [ "$private" = "$1" ]
}
is_empty() {
    entries="$(find "$1" -mindepth 1)"
    [ -z "$entries" ]
}
differs() { [ "$1" != "$2" ]; }
is_gone() { [ ! -e "$1" ]; }
# The folder first, then each home in it, in the order of the names.
stopped_folder_and_homes() {
    printf '%s\n' "--homedir $made --kill gpg-agent" "--homedir $made/home-a --kill gpg-agent" \
        "--homedir $made/home-b --kill gpg-agent" > "$work/want"
    cmp -s "$work/want" "$GPGCONF_LOG"
}

expect "the path is short when TMPDIR is long" is_short "$made"
expect "the folder is private to the user" is_private "$made"
expect "the folder is empty" is_empty "$made"
expect "every call makes its own folder" differs "$made" "$second"

mkdir "$made/home-a" "$made/home-b"
PATH="$work/bin:$PATH" remove_short_tmp "$made"
expect "the folder is removed with its homes" is_gone "$made"
expect "the agent of the folder and of each home in it is stopped" stopped_folder_and_homes

if [ "$failed" -ne 0 ]; then
    echo "$failed short-tmp case(s) failed"
    exit 1
fi
echo "short-tmp: all cases as expected"
