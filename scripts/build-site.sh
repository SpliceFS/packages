#!/bin/sh
# Builds dist/site from the page, the script template and the public keys.
# Variables: KEYS_DIR (default keys, relative to the caller's folder), BASE_URL (default
# https://packages.splicefs.org), OPENPGP_FINGERPRINT (the pinned primary key fingerprint).
set -eu

DEFAULT_URL='https://packages.splicefs.org'
DEFAULT_FPR='93F2C425AA5AC125B6C2D10A47FBE2B821A4E69F'
CALLER_DIR=$(pwd)
BASE_URL=${BASE_URL:-$DEFAULT_URL}
OUT=dist/site

# The pin is skipped for other keys unless the caller states which fingerprint to expect.
if [ -z "${KEYS_DIR:-}" ]; then
  KEYS_DIR=keys
  KEYS_DEFAULT=1
else
  KEYS_DEFAULT=0
fi
if [ -z "${OPENPGP_FINGERPRINT:-}" ]; then
  FPR_SET=0
else
  FPR_SET=1
fi
OPENPGP_FINGERPRINT=${OPENPGP_FINGERPRINT:-$DEFAULT_FPR}

# The URL ends up inside a shell script that runs as root, so only plain URL characters pass.
if ! printf '%s\n' "$BASE_URL" | grep -Eq '^https?://[A-Za-z0-9./:-]+$'; then
  echo "BASE_URL must match ^https?://[A-Za-z0-9./:-]+\$" >&2
  exit 1
fi

# A relative KEYS_DIR is meant relative to where the caller stood, not to the repo root.
case "$KEYS_DIR" in
  /*) ;;
  *) KEYS_DIR=$CALLER_DIR/$KEYS_DIR ;;
esac

cd "$(dirname "$0")/.."

# awk does the replacement because the key is many lines long and sed handles that badly.
# A line holding only the placeholder is swapped for the whole file, which is copied
# verbatim, so no character in the key is ever treated as a pattern. The values travel in
# the environment because awk -v would process backslash escapes in them.
insert_file() {
  PLACEHOLDER=$1 KEYFILE=$2 awk '
    $0 == ENVIRON["PLACEHOLDER"] {
      file = ENVIRON["KEYFILE"]
      while ((getline l < file) > 0) print l
      close(file)
      next
    }
    { print }
  '
}

# Plain text replacement without regular expressions, so "&" and "\" in a URL are safe.
replace_text() {
  FROM=$1 TO=$2 awk '
    BEGIN { from = ENVIRON["FROM"]; to = ENVIRON["TO"] }
    {
      out = ""
      line = $0
      while ((i = index(line, from)) > 0) {
        out = out substr(line, 1, i - 1) to
        line = substr(line, i + length(from))
      }
      print out line
    }
  '
}

if command -v sha256sum >/dev/null 2>&1 && echo x | sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1"; }
elif command -v shasum >/dev/null 2>&1 && echo x | shasum -a 256 >/dev/null 2>&1; then
  hash_file() { shasum -a 256 "$1"; }
else
  echo "neither sha256sum nor shasum works" >&2
  exit 1
fi

for f in "$KEYS_DIR/splicefs.asc" "$KEYS_DIR/splicefs.rsa.pub" install.sh.in site/index.html; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/keys"

# The URL goes in first, so nothing inside a key can ever be taken for a placeholder.
replace_text '@BASE_URL@' "$BASE_URL" < install.sh.in |
  insert_file '@OPENPGP_KEY@' "$KEYS_DIR/splicefs.asc" |
  insert_file '@ALPINE_KEY@' "$KEYS_DIR/splicefs.rsa.pub" > "$OUT/install.sh"
chmod 644 "$OUT/install.sh"

# A cut or mangled script would be run as root by users, so it fails here instead.
sh -n "$OUT/install.sh" || { echo "install.sh has a syntax error" >&2; exit 1; }
if [ "$(tail -n 1 "$OUT/install.sh")" != 'main "$@"' ]; then
  echo 'last line of install.sh is not: main "$@"' >&2
  exit 1
fi

replace_text "$DEFAULT_URL" "$BASE_URL" < site/index.html > "$OUT/index.html"
cp "$KEYS_DIR/splicefs.asc" "$KEYS_DIR/splicefs.rsa.pub" "$OUT/keys/"

# The sha256 file names install.sh without a folder, so it verifies from inside the
# download folder. The hash is taken first, so a failure never leaves an empty file behind.
SUM=$(cd "$OUT" && hash_file install.sh | awk '{ print $1 }')
[ -n "$SUM" ] || { echo "could not compute the sha256 of install.sh" >&2; exit 1; }
printf '%s  install.sh\n' "$SUM" > "$OUT/install.sh.sha256"

# Pull each embedded key block back out of the built script and compare it with its source,
# so a broken replacement fails the build instead of shipping a bad key. The extracts are
# removed whether or not the comparison succeeds.
awk -v out="$OUT" '
  /<<.KEY_EOF.$/ { n++; on = 1; next }
  /^KEY_EOF$/ { on = 0 }
  on { print > (out "/.key" n) }
' "$OUT/install.sh"
KEYS_OK=1
cmp "$OUT/.key1" "$KEYS_DIR/splicefs.asc" || KEYS_OK=0
cmp "$OUT/.key2" "$KEYS_DIR/splicefs.rsa.pub" || KEYS_OK=0
rm -f "$OUT/.key1" "$OUT/.key2"
[ "$KEYS_OK" -eq 1 ] || { echo "embedded key differs from its source" >&2; exit 1; }

# Second place that pins the signing key, next to the fingerprint in the README.
if [ "$KEYS_DEFAULT" -eq 0 ] && [ "$FPR_SET" -eq 0 ]; then
  echo "fingerprint check skipped: KEYS_DIR is not the default and OPENPGP_FINGERPRINT is not set"
elif command -v gpg >/dev/null 2>&1; then
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  FPR=$(gpg --batch --show-keys --with-colons "$KEYS_DIR/splicefs.asc" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1 } $1 == "fpr" && want { print $10; exit }') || FPR=
  rm -rf "$GNUPGHOME"
  unset GNUPGHOME
  if [ "$FPR" != "$OPENPGP_FINGERPRINT" ]; then
    echo "OpenPGP fingerprint is '$FPR', expected $OPENPGP_FINGERPRINT" >&2
    exit 1
  fi
  echo "OpenPGP fingerprint matches"
else
  echo "fingerprint check skipped: gpg is not on the PATH"
fi
echo "built $OUT"
