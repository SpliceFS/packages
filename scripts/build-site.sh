#!/bin/sh
# Builds dist/site from the page, the script template and the public keys.
# Variables: KEYS_DIR (default keys), BASE_URL (default https://packages.splicefs.org).
set -eu

DEFAULT_URL='https://packages.splicefs.org'
KEYS_DIR=${KEYS_DIR:-keys}
BASE_URL=${BASE_URL:-$DEFAULT_URL}
OUT=dist/site

cd "$(dirname "$0")/.."

# awk does the replacement because the key is many lines long and sed handles that badly.
# A line holding only the placeholder is swapped for the whole file, which is copied
# verbatim, so no character in the key is ever treated as a pattern.
insert_file() {
  awk -v ph="$1" -v file="$2" '
    $0 == ph { while ((getline l < file) > 0) print l; close(file); next }
    { print }
  '
}

# Plain text replacement without regular expressions, so "&" and "\" in a URL are safe.
replace_text() {
  awk -v from="$1" -v to="$2" '
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

if command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1"; }
else
  hash_file() { shasum -a 256 "$1"; }
fi

for f in "$KEYS_DIR/splicefs.asc" "$KEYS_DIR/splicefs.rsa.pub" install.sh.in site/index.html; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/keys"

insert_file '@OPENPGP_KEY@' "$KEYS_DIR/splicefs.asc" < install.sh.in |
  insert_file '@ALPINE_KEY@' "$KEYS_DIR/splicefs.rsa.pub" |
  replace_text '@BASE_URL@' "$BASE_URL" > "$OUT/install.sh"
chmod 644 "$OUT/install.sh"

replace_text "$DEFAULT_URL" "$BASE_URL" < site/index.html > "$OUT/index.html"
cp "$KEYS_DIR/splicefs.asc" "$KEYS_DIR/splicefs.rsa.pub" "$OUT/keys/"

# The sha256 file names install.sh without a folder, so it verifies from inside the
# download folder.
(cd "$OUT" && hash_file install.sh | awk '{ print $1 "  install.sh" }' > install.sh.sha256)

# Pull each embedded key block back out of the built script and compare it with its source,
# so a broken replacement fails the build instead of shipping a bad key.
awk -v out="$OUT" '
  /<<.KEY_EOF.$/ { n++; on = 1; next }
  /^KEY_EOF$/ { on = 0 }
  on { print > (out "/.key" n) }
' "$OUT/install.sh"
cmp "$OUT/.key1" "$KEYS_DIR/splicefs.asc"
cmp "$OUT/.key2" "$KEYS_DIR/splicefs.rsa.pub"
rm -f "$OUT/.key1" "$OUT/.key2"
echo "built $OUT"
