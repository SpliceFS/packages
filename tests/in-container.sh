#!/bin/sh
# Runs as root inside the system under test (started by tests/run.sh). Tests the script path
# only: sh /site/install.sh, then idempotency, repair, bad arguments and removal.
# Usage: in-container.sh deb|rpm|apk. The site is mounted read-only at /site.
set -eu

format=${1:?usage: in-container.sh deb|rpm|apk}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The two files the script writes, the folders it may leave a temporary file in, and the
# package query that says whether a package is installed. Minimal images differ in tools,
# so everything here is plain sh, sha256sum and stat.
case "$format" in
  deb)
    keyfile=/etc/apt/keyrings/splicefs.asc
    srcfile=/etc/apt/sources.list.d/splicefs.sources
    tmpdirs="/etc/apt/keyrings /etc/apt/sources.list.d"
    sitekey=/site/keys/splicefs.asc
    # dpkg -s also succeeds for a removed package whose configuration files remain.
    is_installed() {
      dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
    }
    remove_pkgs() { DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@"; }
    ;;
  rpm)
    keyfile=/etc/pki/rpm-gpg/RPM-GPG-KEY-splicefs
    sitekey=/site/keys/splicefs.asc
    if command -v zypper >/dev/null 2>&1; then
      srcfile=/etc/zypp/repos.d/splicefs.repo
      remove_pkgs() { zypper --non-interactive remove "$@"; }
    else
      srcfile=/etc/yum.repos.d/splicefs.repo
      if command -v dnf >/dev/null 2>&1; then
        remove_pkgs() { dnf remove -y "$@"; }
      else
        remove_pkgs() { yum remove -y "$@"; }
      fi
    fi
    tmpdirs="/etc/pki/rpm-gpg $(dirname "$srcfile")"
    is_installed() { rpm -q "$1" >/dev/null 2>&1; }
    ;;
  apk)
    keyfile=/etc/apk/keys/splicefs.rsa.pub
    srcfile=/etc/apk/repositories.d/splicefs.list
    # The script keeps its temporary key file in /etc/apk, outside the keys folder.
    tmpdirs="/etc/apk/keys /etc/apk/repositories.d /etc/apk"
    sitekey=/site/keys/splicefs.rsa.pub
    is_installed() { apk info -e "$1" >/dev/null 2>&1; }
    remove_pkgs() { apk del "$@"; }
    ;;
  *) fail "unknown format '$format'" ;;
esac
files="$keyfile $srcfile"
out=$(mktemp)
trap 'rm -f "$out"' EXIT

# One line per file: checksum, modification time (seconds) and mode.
state() {
  for f in $files; do
    [ -f "$f" ] || { echo "$f missing"; continue; }
    echo "$f $(sha256sum "$f" | cut -d' ' -f1) $(stat -c %Y "$f") $(stat -c %a "$f")"
  done
}

no_temp_files() {
  for d in $tmpdirs; do
    if [ -n "$(find "$d" -maxdepth 1 -name '*.new' 2>/dev/null)" ]; then
      fail "temporary file left in $d"
    fi
  done
}

# cmp is missing on some minimal images, so files are compared by checksum.
same_file() {
  [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]
}

# Runs the install script, keeps its output in $out and echoes it, and returns its status.
run_script() {
  rc=0
  sh /site/install.sh "$@" >"$out" 2>&1 || rc=$?
  cat "$out"
  return "$rc"
}

# The file only exists on the system under test.
# shellcheck disable=SC1091
pretty=$( . /etc/os-release >/dev/null 2>&1; printf %s "${PRETTY_NAME:-$format}" )

# a. the script succeeds
run_script both || fail "install.sh both exited $?"

# b. both programs and both packages are there
splicefsd --version | grep -q . || fail "splicefsd --version printed nothing"
splicefs --version | grep -q . || fail "splicefs --version printed nothing"
for p in splicefs-server splicefs-client; do
  is_installed "$p" || fail "$p is not installed according to the package manager"
done

# c. files, modes, no temporary files
for f in $files; do
  [ -f "$f" ] || fail "$f was not written"
  [ "$(stat -c %a "$f")" = 644 ] || fail "$f has mode $(stat -c %a "$f"), expected 644"
done
same_file "$keyfile" "$sitekey" || fail "$keyfile differs from the published key"
no_temp_files
before=$(state)

# d. a second run changes nothing, not even a modification time. The sleep makes a rewrite
# visible, because mtime has one second resolution on some filesystems.
sleep 2
run_script both || fail "second install.sh both exited $?"
if grep -q '^updated ' "$out"; then fail "second run printed an updated line"; fi
[ "$(state)" = "$before" ] || fail "second run changed a file (checksum, mtime or mode)"
no_temp_files

# e. repair: a deleted key and a damaged source file come back, and only those two are
# reported
rm -f "$keyfile"
echo "junk line" >>"$srcfile"
run_script server || fail "repair run exited $?"
[ "$(grep -c '^updated ' "$out")" -eq 2 ] || fail "repair run did not print exactly two updated lines"
grep -q "^updated $keyfile\$" "$out" || fail "repair run did not report $keyfile"
grep -q "^updated $srcfile\$" "$out" || fail "repair run did not report $srcfile"
same_file "$keyfile" "$sitekey" || fail "$keyfile was not restored"
# Checksum and mode only: the restored files are new, so their mtime differs on purpose.
[ "$(state | cut -d' ' -f1,2,4)" = "$(echo "$before" | cut -d' ' -f1,2,4)" ] ||
  fail "files are not back to their original content and mode"
no_temp_files

# f. argument errors exit 2 and touch nothing
before=$(state)
sleep 1
rc=0
sh /site/install.sh >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "install.sh without argument exited $rc, expected 2"
rc=0
sh /site/install.sh nonsense >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "install.sh nonsense exited $rc, expected 2"
[ "$(state)" = "$before" ] || fail "an argument error changed a file"

# g. the package manager can remove what the script installed
remove_pkgs splicefs-server splicefs-client || fail "removing the packages failed"
for p in splicefs-server splicefs-client; do
  if is_installed "$p"; then fail "$p is still installed after removal"; fi
done

echo "install test passed on $pretty"
