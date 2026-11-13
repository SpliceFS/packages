#!/bin/sh
# Signs dist/site/setup.sh and proves the signature with the published public key only.
# Variables: SIGNING_KEY_FILE (required, armored secret key file), SITE_DIR (default
# dist/site), KEYS_DIR (default keys; must hold splicefs.asc). Relative paths are relative
# to the caller's folder, except the defaults, which are in the repository.
set -eu

if [ -z "${SIGNING_KEY_FILE:-}" ]; then
  echo "SIGNING_KEY_FILE is not set" >&2
  exit 1
fi
if [ ! -f "$SIGNING_KEY_FILE" ] || [ ! -r "$SIGNING_KEY_FILE" ]; then
  echo "SIGNING_KEY_FILE is not a readable file" >&2
  exit 1
fi
command -v gpg >/dev/null 2>&1 || { echo "gpg is not on the PATH" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SITE=${SITE_DIR:-$ROOT/dist/site}
KEYS=${KEYS_DIR:-$ROOT/keys}
[ -f "$SITE/setup.sh" ] || { echo "missing $SITE/setup.sh, run make site first" >&2; exit 1; }
[ -f "$KEYS/splicefs.asc" ] || { echo "missing $KEYS/splicefs.asc" >&2; exit 1; }

# Two separate homes: the signing home holds the secret key, and the verifying home holds
# only the public key, so the proof cannot be satisfied by the key that made the signature.
# Both are removed on every exit path, including failure and interrupts.
SIGN_HOME=$(mktemp -d)
VERIFY_HOME=$(mktemp -d)
TMPOUT=$(mktemp -d)
cleanup() { rm -rf "$SIGN_HOME" "$VERIFY_HOME" "$TMPOUT"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
chmod 700 "$SIGN_HOME" "$VERIFY_HOME"

# Output of gpg goes to a file and is shown only on failure; it never contains key material.
if ! GNUPGHOME=$SIGN_HOME gpg --batch --quiet --import "$SIGNING_KEY_FILE" \
  > "$TMPOUT/log" 2>&1
then
  echo "could not import the signing key" >&2
  exit 1
fi
if ! GNUPGHOME=$SIGN_HOME gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --armor --detach-sign --output "$TMPOUT/setup.sh.asc" "$SITE/setup.sh" > "$TMPOUT/log" 2>&1
then
  echo "signing failed" >&2
  sed 's/^/  /' "$TMPOUT/log" >&2
  exit 1
fi

if ! GNUPGHOME=$VERIFY_HOME gpg --batch --quiet --import "$KEYS/splicefs.asc" > "$TMPOUT/log" 2>&1
then
  echo "could not import $KEYS/splicefs.asc" >&2
  exit 1
fi
WANT=$(GNUPGHOME=$VERIFY_HOME gpg --batch --with-colons --list-keys 2>/dev/null |
  awk -F: '$1 == "pub" { want = 1 } $1 == "fpr" && want { print $10; exit }')
[ -n "$WANT" ] || { echo "no fingerprint in $KEYS/splicefs.asc" >&2; exit 1; }

# VALIDSIG field 11 is the primary key fingerprint, which holds for a signing subkey too.
if ! GNUPGHOME=$VERIFY_HOME gpg --batch --status-fd 1 \
  --verify "$TMPOUT/setup.sh.asc" "$SITE/setup.sh" > "$TMPOUT/status" 2>/dev/null
then
  echo "the signature does not verify against $KEYS/splicefs.asc" >&2
  exit 1
fi
GOT=$(awk '$2 == "VALIDSIG" { print $12 }' "$TMPOUT/status")
if [ "$GOT" != "$WANT" ]; then
  echo "the signature was not made by the key $WANT" >&2
  exit 1
fi

cp "$TMPOUT/setup.sh.asc" "$SITE/setup.sh.asc"
chmod 644 "$SITE/setup.sh.asc"
echo "signed $SITE/setup.sh, verified against key $WANT"
