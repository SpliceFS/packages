#!/bin/sh
# check: published-site-lib.sh: the published site is the downloaded setup script with the keys of the repository
# Test of scripts/published-site-lib.sh (part of make check): the folder the end to end tests
# (tests/run.sh, tests/freebsd.sh) make of the published site. A stand-in curl serves the setup script from a
# file, so nothing goes to the network and nothing waits. Runs on the host.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# shellcheck source=fetch-lib.sh
. "$root/scripts/fetch-lib.sh"
# shellcheck source=published-site-lib.sh
. "$root/scripts/published-site-lib.sh"

# $1 what is tested, $2 the text wanted, $3 the text got.
same() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

# $1 what is tested, $2 the text wanted, then a command whose output (standard error too) is the
# text got.
output_is() {
    oi_name="$1"
    oi_want="$2"
    shift 2
    oi_got="$("$@" 2>&1)" || true
    same "$oi_name" "$oi_want" "$oi_got"
}

# Says whether the path $1 exists, in words that no system words differently.
exists() {
    if [ -e "$1" ]; then echo present; else echo absent; fi
}

# --- the published site ---------------------------------------------------------------------
# A stand-in curl: it writes the file named by the argument of -o from $STUB_SERVED, or fails when
# there is none, and records the address it was asked for.
mkdir "$work/bin"
cat > "$work/bin/curl" <<'STUB'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --proto | --proto-redir | --retry) shift 2 ;;
        *) url="$1"; shift ;;
    esac
done
echo "$url" >> "$STUB_REQUESTS"
[ -f "$STUB_SERVED" ] || exit 22
cp "$STUB_SERVED" "$out"
STUB
chmod 755 "$work/bin/curl"
STUB_REQUESTS="$work/requests"
STUB_SERVED="$work/served"
export STUB_REQUESTS STUB_SERVED
PATH="$work/bin:$PATH"

mkdir -p "$work/repo/keys"
printf 'openpgp key\n' > "$work/repo/keys/splicefs.asc"
printf 'alpine key\n' > "$work/repo/keys/splicefs.rsa.pub"
printf 'published setup script\n' > "$work/served"
: > "$work/requests"

site="$work/site"
mkdir -p "$site/old"
echo stale > "$site/old/file"
fetch_published_site "$site" "$work/repo"
output_is "the setup script is the published one" "published setup script" cat "$site/setup.sh"
output_is "the key files are those of the repository" "openpgp key
alpine key" cat "$site/keys/splicefs.asc" "$site/keys/splicefs.rsa.pub"
output_is "nothing of an earlier site is left" absent exists "$site/old"
output_is "only the setup script is downloaded, from the published site" "https://packages.splicefs.org/setup.sh" cat "$work/requests"

: > "$work/requests"
PACKAGE_SITE=https://packages.example.test
# The address is read when the library is sourced, so the library is sourced again.
# shellcheck disable=SC1090,SC1091
(. "$root/scripts/published-site-lib.sh"; fetch_published_site "$work/other" "$work/repo")
output_is "PACKAGE_SITE names another site" "https://packages.example.test/setup.sh" cat "$work/requests"
PACKAGE_SITE=

rm "$work/served"
set +e
(fetch_published_site "$work/failed" "$work/repo") >"$work/failed.out" 2>&1
status=$?
set -e
same "a download that fails ends the caller" 1 "$status"
output_is "a download that fails says what it could not get" "could not download https://packages.splicefs.org/setup.sh" cat "$work/failed.out"
output_is "a download that fails leaves no setup script" absent exists "$work/failed/setup.sh"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "published-site checks done"
