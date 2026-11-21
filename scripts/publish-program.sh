#!/bin/sh
# Publishes the package repositories of a program, in dist/PROGRAM/repo, to the folder of that
# program on packages.splicefs.org by rsync, or proves that the upload path works. Runs on the
# host (make program-fetch, program-publish, program-publish-check, and the publish-program
# workflow). It is the same for every program: the program is the folder of programs/ that
# PROGRAM names, and the remote folder has its name.
# Usage: publish-program.sh fetch | publish-program.sh send | publish-program.sh check
#   fetch  downloads what is published now into dist/PROGRAM/repo, so the repository that is
#          built keeps every older version. An empty remote is fine (the first release).
#   send   uploads dist/PROGRAM/repo in three passes: the packages, then the index files that
#          the entry files (Release, repomd.xml, ...) name, then the entry files and the
#          deletions. A published package is never deleted, and never replaced by a file with
#          other content under the same name. An index file is deleted only when neither the
#          upload nor the one it replaces names it, so a client in the middle of an update
#          still finds what it was told about.
#   check  lists the remote folder of the program and changes nothing.
# Variables: PROGRAM (required), REPO_DIR (default dist/PROGRAM/repo), UPLOAD_HOST
# (packages.splicefs.org), UPLOAD_PORT (7022), UPLOAD_USER (site-splicefs-packages),
# UPLOAD_KEY_FILE (required, private key, mode 600), UPLOAD_KNOWN_HOSTS_FILE (required). The key
# of this repository reaches the whole site (publish.sh sends the setup script to its root), so
# the folder of the program is the first part of the remote path. Test hook: UPLOAD_TARGET is
# a complete rsync destination, for example a local folder. It replaces user@host:/PROGRAM/ and
# no ssh options are used then, so the checks can run without a server.
set -eu

MODE=${1:-}
case "$MODE" in
  fetch | send | check) ;;
  *) echo "usage: publish-program.sh fetch|send|check" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Says which program PROGRAM is and refuses one that this repository does not package, before
# anything is read or sent.
cd "$ROOT"
# shellcheck source=program-conf.sh
. scripts/program-conf.sh
REPO=${REPO_DIR:-$ROOT/dist/$PROGRAM/repo}
HOST=${UPLOAD_HOST:-packages.splicefs.org}
PORT=${UPLOAD_PORT:-7022}
USER_NAME=${UPLOAD_USER:-site-splicefs-packages}

if [ -n "${UPLOAD_TARGET:-}" ]; then
  # The trailing slash makes rsync copy the content of the folder, as it does for remote /.
  DEST=${UPLOAD_TARGET%/}/
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
  DEST=$USER_NAME@$HOST:/$PROGRAM/
fi

# Runs rsync with the common options: -e only when there is a real host.
run_rsync() {
  if [ -n "${UPLOAD_TARGET:-}" ]; then
    rsync "$@"
  else
    rsync -e "$SSH_CMD" "$@"
  fi
}

if [ "$MODE" = check ]; then
  # Read only: lists the remote root and prints the entry names.
  run_rsync --list-only "$DEST" |
    awk '{ $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); if ($0 != "" && $0 != ".") print }'
  exit 0
fi

if [ "$MODE" = fetch ]; then
  # No delete option: a half built local repository is never emptied by a fetch, and the
  # repository scripts add to what is there.
  mkdir -p "$REPO"
  run_rsync -a "$DEST" "$REPO/"
  echo "fetched ${UPLOAD_TARGET:-$HOST} into $REPO"
  exit 0
fi

# An unsigned or partial repository must never go live, so every file has to exist first.
for f in apt/dists/stable/InRelease rpm/x86_64/repodata/repomd.xml.asc \
  rpm/aarch64/repodata/repomd.xml.asc alpine/x86_64/APKINDEX.tar.gz \
  alpine/aarch64/APKINDEX.tar.gz; do
  [ -f "$REPO/$f" ] || { echo "missing $REPO/$f, run make repo first" >&2; exit 1; }
done
# The FreeBSD versions come from the list the packages are built for, so they are written
# down once. Each major version has one folder for each CPU type, and a release that left no
# catalog for one of them would go out with the old catalog of that folder, without its package.
majors=$(awk '!/^#/ && NF { split($1, v, "."); print v[1] }' \
  "$ROOT/packaging/freebsd/releases" | sort -un)
for major in $majors; do
  for arch in amd64 aarch64; do
    f=freebsd/FreeBSD:$major:$arch/meta.conf
    [ -f "$REPO/$f" ] || { echo "missing $REPO/$f, run make package-freebsd first" >&2; exit 1; }
  done
done

# A published package must never disappear, and the repository built from fetch holds every
# old package, so a deletion means something went wrong. Only three kinds of file may go:
# everything inside a repodata folder (its files carry a hash in the name, so every new build
# replaces them), everything inside a by-hash folder (a copy of an index file under its hash,
# for every generation of the index) and the index files of a format (APKINDEX.tar.gz,
# Packages*, Release*, InRelease), which a new build rewrites.
OWN_ALLOWED='(^|/)(repodata|by-hash)/'
OWN_ALLOWED="$OWN_ALLOWED"'|(^|/)(APKINDEX\.tar\.gz|InRelease|Packages(\.[a-z0-9]+)*'
OWN_ALLOWED="$OWN_ALLOWED"'|Release(\.[a-z0-9]+)*)$'
# The index files are what apt, dnf, apk and pkg read to learn which packages exist: the apt
# dists folder, the rpm repodata folders, APKINDEX.tar.gz, the FreeBSD catalog (meta,
# meta.conf, packagesite.pkg, data.pkg) and the signature files next to them. A new index
# that is in place before the packages it names are makes a client ask for a file that is not
# there yet. rsync --delay-updates cannot prevent that alone, because it moves the files into
# place one after another. The same goes for the index files themselves: a Release or a
# repomd.xml that is in place before the files it names makes a client ask for a file that is
# not there yet. So the upload runs in three passes and the script stops at the first one that
# fails: pass 1 sends everything except the index files, pass 2 sends the index files that the
# entry files name (Packages, the by-hash copies, the files of repodata), pass 3 sends the
# entry files (and does the deletions). The patterns start with / so that they match from the
# top of the repository folder only.
ENTRY_PATTERNS='/apt/dists/*/Release /apt/dists/*/Release.gpg /apt/dists/*/InRelease'
ENTRY_PATTERNS="$ENTRY_PATTERNS /rpm/*/repodata/repomd.xml*"
ENTRY_PATTERNS="$ENTRY_PATTERNS /alpine/*/APKINDEX.tar.gz /alpine/*/*.sig /alpine/*/*.asc"
ENTRY_PATTERNS="$ENTRY_PATTERNS /freebsd/*/meta /freebsd/*/meta.conf"
ENTRY_PATTERNS="$ENTRY_PATTERNS /freebsd/*/packagesite.pkg /freebsd/*/data.pkg"
ENTRY_PATTERNS="$ENTRY_PATTERNS /freebsd/*/*.sig /freebsd/*/*.asc"
INDEX_PATTERNS="$ENTRY_PATTERNS /apt/dists/*** /rpm/*/repodata/***"
# The same index files as one extended regular expression, for the lines of rsync's dry run
# (paths relative to the repository folder): a leading / anchors at the top, *** is anything
# below, * is anything within one folder name.
# The patterns hold *, so file name expansion is off while they are read.
set -f
INDEX_REGEX=$(for pattern in $INDEX_PATTERNS; do
  printf '%s\n' "$pattern" | sed -e 's/[.]/\\./g' -e 's#^/#^#' -e 's#[*][*][*]#@ANY@#g' \
    -e 's#[*]#[^/]*#g' -e 's#@ANY@#.*#g' -e 's/$/$/'
done | paste -sd '|' -)
set +f

WORK=$(mktemp -d)
DRY="$WORK/dry"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
# set -e is switched off around the call, not by using it as a condition, which would also
# switch it off inside run_rsync.
# --checksum makes the dry run see a change of content and not of time stamps, so that the same
# package built into the folder again is no change.
set +e
run_rsync -a --checksum --chmod=D755,F644 --delete --dry-run --itemize-changes "$REPO/" "$DEST" \
  > "$DRY"
dry_status=$?
set -e
if [ "$dry_status" -ne 0 ]; then
  echo "the dry run failed, nothing was sent" >&2
  exit 1
fi
# A deleted folder is listed with a trailing slash after its files, each of which was checked.
BAD=$(awk '$1 == "*deleting" { $1 = ""; sub(/^ +/, ""); print }' "$DRY" |
  grep -v '/$' | grep -Ev "$OWN_ALLOWED" || true)
if [ -n "$BAD" ]; then
  echo "refusing to send: it would delete published files:" >&2
  echo "$BAD" | sed 's/^/  /' >&2
  exit 1
fi

# A published package is never replaced by a file with other content under the same name. A
# change of the packaging is not published for a release that is published, so the file that
# clients and the signatures of the indexes were made from stays what it was. An existing file
# that the upload would change shows in the dry run as ">f" followed by something other than
# the "+" of a new file; the index files are the only ones a new build rewrites.
REPLACED=$(awk '$1 ~ /^>f[^+]/ { $1 = ""; sub(/^ +/, ""); print }' "$DRY" |
  grep -Ev "$INDEX_REGEX" || true)
if [ -n "$REPLACED" ]; then
  echo "refusing to send: it would replace published files with other content under the same name" >&2
  echo "(a package of a published release is never changed):" >&2
  echo "$REPLACED" | sed 's/^/  /' >&2
  exit 1
fi


# The Release and the repomd.xml that this upload replaces, as they are published now. A client
# that read them is still fetching the files they name while the upload runs and after it, so
# those files are kept (see pass 3). A first publication has none, and the filters below leave
# every file out that is not there, so nothing is read and nothing protected.
set -f
set -- -a
for dir in /apt/ /apt/dists/ '/apt/dists/*/' '/rpm/' '/rpm/*/' '/rpm/*/repodata/'; do
  set -- "$@" "--include=$dir"
done
set -- "$@" '--include=/apt/dists/*/Release' '--include=/rpm/*/repodata/repomd.xml' '--exclude=*'
set +f
set +e
run_rsync "$@" "$DEST" "$WORK/replaced/"
replaced_status=$?
set -e
if [ "$replaced_status" -ne 0 ]; then
  echo "could not read the published Release and repomd.xml, nothing was sent" >&2
  exit 1
fi

# Names of the files that the replaced Release and repomd.xml list, one a line: the hashes of a
# Release (every hash type, the by-hash copies carry the hash as their name) and the files of
# a repomd.xml. The characters are limited to what such a name holds, so that nothing read from
# the server can be taken for a filter rule.
replaced_names() {
  [ ! -d "$WORK/replaced" ] || {
    find "$WORK/replaced" -name Release -type f \
      -exec awk '/^ [0-9a-f]+ +[0-9]+ /{ print $1 }' {} +
    find "$WORK/replaced" -name repomd.xml -type f \
      -exec sed -n 's|.*<location href="repodata/\([A-Za-z0-9._-]*\)".*|\1|p' {} +
  }
}

# Runs one pass: $1 names it for the message, the other arguments are rsync options. A failed
# pass ends the script, so a later pass never sends an index for files that an earlier one did
# not deliver. set -e is switched off around the call, not by using it as a condition, which
# would also switch it off inside run_rsync.
send_pass() {
  pass_name=$1
  shift
  set +e
  run_rsync "$@" "$REPO/" "$DEST"
  pass_status=$?
  set -e
  if [ "$pass_status" -ne 0 ]; then
    echo "the upload stopped: $pass_name failed" >&2
    exit 1
  fi
}

# Pass 1: no deletions, and every index file left out. The patterns hold * and must reach
# rsync as they are, so file name expansion is off while the options are built. --checksum: a
# file is sent when its content differs. rsync's own test, size and time stamp, misses a file
# that changed but kept its size within the same second of its published copy, as an index
# rebuilt right after a publish can.
set -f
set -- -a --checksum --chmod=D755,F644 --delay-updates
for pattern in $INDEX_PATTERNS; do
  set -- "$@" "--exclude=$pattern"
done
set +f
send_pass "pass 1 (everything except the index files)" "$@"

# Pass 2: the same upload again, with only the entry files left out. Everything pass 1 sent is
# there and unchanged, so rsync skips it, and what is sent is the index files that the entry
# files name. No deletions yet: the files of the replaced index are still in use.
set -f
set -- -a --checksum --chmod=D755,F644 --delay-updates
for pattern in $ENTRY_PATTERNS; do
  set -- "$@" "--exclude=$pattern"
done
set +f
send_pass "pass 2 (the index files that the entry files name)" "$@"

# Pass 3: the same upload again, now with the entry files and the deletions. What is left to send
# is the entry files. --delete-after removes only after every file has arrived. The filter rules
# are checked in order and the first match wins: P keeps the files that the replaced Release and
# repomd.xml name, R lets rsync delete what matches (the repodata and by-hash folders and the
# index files, the same set the dry run allowed), and the final P * protects everything else, so
# even a file the dry run missed cannot be deleted. So a file of an index generation goes only
# when neither this upload nor the one it replaces names it.
set -f
set -- -a --checksum --chmod=D755,F644 --delay-updates --delete-after
for name in $(replaced_names | sort -u); do
  set -- "$@" "--filter=P $name"
done
set -- "$@" --filter='R repodata/***' --filter='R by-hash/***' --filter='R APKINDEX.tar.gz' \
  --filter='R Packages*' --filter='R Release*' --filter='R InRelease' --filter='P *'
set +f
send_pass "pass 3 (the entry files and the deletions)" "$@"
echo "published to ${UPLOAD_TARGET:-$HOST}"
