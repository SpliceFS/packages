#!/bin/sh
# check: published-site-lib.sh: SOURCE is built or published, and the published site is the downloaded setup script with the keys of the repository
# Test of scripts/published-site-lib.sh (part of make check): the word SOURCE that tells the end to
# end tests (tests/run.sh, tests/freebsd.sh) where their setup script and packages come from, and
# the folder they make of the published site. A stand-in curl serves the setup script from a
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

# --- SOURCE ---------------------------------------------------------------------------------
# $1 case name, $2 the value of SOURCE ("unset" for none), $3 the word wanted or "refused".
source_word() {
    if [ "$2" = unset ]; then
        got="$(unset SOURCE; check_install_source 2>/dev/null && echo "$install_source")" || got=refused
    else
        got="$(SOURCE="$2"; export SOURCE; check_install_source 2>/dev/null && echo "$install_source")" || got=refused
    fi
    same "$1" "$3" "$got"
}
source_word "no SOURCE is the built packages" unset built
source_word "an empty SOURCE is the built packages" '' built
source_word "SOURCE built" built built
source_word "SOURCE published" published published
source_word "another word is refused" published-site refused
source_word "a capital letter is another word" Published refused

message="$(SOURCE=nonsense check_install_source 2>&1 >/dev/null)" || true
case "$message" in
    *"SOURCE must be built or published, not 'nonsense'"*) printf 'ok   the refusal names the word\n' ;;
    *) printf 'FAIL the refusal does not name the word: %s\n' "$message"; failed=$((failed + 1)) ;;
esac

# --- the published site ---------------------------------------------------------------------
# A stand-in curl: it writes the file named by the argument of -o from $work/served, or fails when
# there is none, and records the address it was asked for.
mkdir "$work/bin"
cat > "$work/bin/curl" <<'EOF'
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
EOF
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
same "the setup script is the published one" "published setup script" "$(cat "$site/setup.sh")"
same "the keys are those of the repository" "openpgp key alpine key" \
    "$(cat "$site/keys/splicefs.asc" "$site/keys/splicefs.rsa.pub" | tr '\n' ' ' | sed 's/ $//')"
same "nothing of an earlier site is left" "" "$(ls "$site/old" 2>/dev/null || true)"
same "only the setup script is downloaded, from the published site" "https://packages.splicefs.org/setup.sh" "$(cat "$work/requests")"

: > "$work/requests"
PACKAGE_SITE=https://packages.example.test
(. "$root/scripts/published-site-lib.sh"; fetch_published_site "$work/other" "$work/repo")
same "PACKAGE_SITE names another site" "https://packages.example.test/setup.sh" "$(cat "$work/requests")"

rm "$work/served"
status=0
(fetch_published_site "$work/failed" "$work/repo") >/dev/null 2>&1 || status=$?
same "a download that fails fails the call" 1 "$status"
same "a download that fails leaves no setup script" "" "$(ls "$work/failed/setup.sh" 2>/dev/null || true)"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "published-site checks done"
