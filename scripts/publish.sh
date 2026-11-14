#!/bin/sh
# Publishes the signed site files by rsync, or proves that the upload path works.
# Usage: publish.sh send | publish.sh check
# send uploads in three passes: the page and the keys, then setup.sh, then its hash and its
# signature.
# Variables: SITE_DIR (default dist/site), UPLOAD_HOST (packages.splicefs.org), UPLOAD_PORT
# (7022), UPLOAD_USER (site-splicefs-packages), UPLOAD_KEY_FILE (required, private key,
# mode 600), UPLOAD_KNOWN_HOSTS_FILE (required). Test hook: UPLOAD_TARGET is a complete
# rsync destination, for example a local folder. It replaces user@host:/ and no ssh options
# are used then, so the checks can run without a server.
set -eu

MODE=${1:-}
case "$MODE" in
  send | check) ;;
  *) echo "usage: publish.sh send|check" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SITE=${SITE_DIR:-$ROOT/dist/site}
HOST=${UPLOAD_HOST:-packages.splicefs.org}
PORT=${UPLOAD_PORT:-7022}
USER_NAME=${UPLOAD_USER:-site-splicefs-packages}

# The only files this repository owns on the site. The server and client folders next to
# them belong to other pipelines, so nothing else is ever sent and nothing is ever deleted.
FILES='index.html setup.sh setup.sh.sha256 setup.sh.asc'
FILES="$FILES keys/splicefs.asc keys/splicefs.rsa.pub"

if [ "$MODE" = send ]; then
  # An unsigned or partial site must never go live, so every file has to exist first.
  for f in $FILES; do
    [ -f "$SITE/$f" ] || { echo "missing $SITE/$f, run make sign first" >&2; exit 1; }
  done
fi

if [ -n "${UPLOAD_TARGET:-}" ]; then
  DEST=$UPLOAD_TARGET
else
  : "${UPLOAD_KEY_FILE:?UPLOAD_KEY_FILE is not set}"
  : "${UPLOAD_KNOWN_HOSTS_FILE:?UPLOAD_KNOWN_HOSTS_FILE is not set}"
  [ -f "$UPLOAD_KEY_FILE" ] || { echo "UPLOAD_KEY_FILE is not a file" >&2; exit 1; }
  [ -f "$UPLOAD_KNOWN_HOSTS_FILE" ] || { echo "UPLOAD_KNOWN_HOSTS_FILE is not a file" >&2; exit 1; }
  # ssh refuses a loose key anyway; failing here gives a clearer message before any connect.
  # shellcheck disable=SC2012 # ls prints the same mode string on macOS and Linux, stat does not
  KEY_MODE=$(ls -ld "$UPLOAD_KEY_FILE" | cut -c1-10)
  if [ "$KEY_MODE" != '-rw-------' ]; then
    echo "UPLOAD_KEY_FILE must have mode 600" >&2
    exit 1
  fi
  # Only the given key and the pinned host key are trusted: no agent, no prompts, no
  # fallback to the user's own ssh configuration.
  SSH_CMD="ssh -p $PORT -i $UPLOAD_KEY_FILE -o IdentitiesOnly=yes -o IdentityAgent=none"
  SSH_CMD="$SSH_CMD -o BatchMode=yes -o StrictHostKeyChecking=yes"
  SSH_CMD="$SSH_CMD -o UserKnownHostsFile=$UPLOAD_KNOWN_HOSTS_FILE -F /dev/null"
  DEST=$USER_NAME@$HOST:/
fi

if [ "$MODE" = check ]; then
  # Read only: lists the remote root and prints the entry names.
  if [ -n "${UPLOAD_TARGET:-}" ]; then
    rsync --list-only "$DEST"
  else
    rsync --list-only -e "$SSH_CMD" "$DEST"
  fi | awk '{ $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); if ($0 != "" && $0 != ".") print }'
  exit 0
fi

# Run from the site folder with --relative so keys/ lands as keys/ and nothing else is
# named. There is no delete option, on purpose.
cd "$SITE"

run_rsync() {
  if [ -n "${UPLOAD_TARGET:-}" ]; then
    rsync "$@"
  else
    rsync -e "$SSH_CMD" "$@"
  fi
}

# Runs one pass: $1 names it for the message, the other arguments are the files. A failed pass
# ends the script, so a later pass never sends a file that depends on one that did not arrive.
# --delay-updates moves the files of one pass into place together at the end of that pass.
# set -e is switched off around the call, not by using it as a condition, which would also
# switch it off inside run_rsync.
send_pass() {
  pass_name=$1
  shift
  set +e
  run_rsync -a --chmod=D755,F644 --delay-updates --relative "$@" "$DEST"
  pass_status=$?
  set -e
  if [ "$pass_status" -ne 0 ]; then
    echo "the upload stopped: $pass_name failed" >&2
    exit 1
  fi
}

# The setup script holds the public keys, and it checks itself against setup.sh.sha256 before
# it changes anything. So everything else goes first, then the script, then its hash and its
# signature right after it: a reader must never get a new script with an old hash for longer
# than the time between the last two passes. A client that fetches in that instant gets the
# new script and the old hash. The self-check then stops it and tells the person to download
# the script again, which is the safe direction.
send_pass "pass 1 (the page and the keys)" index.html keys/splicefs.asc keys/splicefs.rsa.pub
send_pass "pass 2 (setup.sh)" setup.sh
send_pass "pass 3 (setup.sh.sha256 and setup.sh.asc)" setup.sh.sha256 setup.sh.asc
echo "published to ${UPLOAD_TARGET:-$HOST}"
