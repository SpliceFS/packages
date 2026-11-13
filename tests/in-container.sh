#!/bin/sh
# Runs as root inside the system under test (started by tests/run.sh). Tests the setup script
# and then the commands it prints: sh /site/setup.sh must only register the repository, and
# the printed index refresh and installs must then really install both packages.
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
first=$(mktemp)
trap 'rm -f "$out" "$first"' EXIT
# The printed apt-get commands must not stop to ask about debconf questions.
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# Runs a command that asks a question: a non-zero status is an answer, not an error, so it
# is left in $status and the script goes on. set -e is off while the command runs, as it is
# for a command in an if or after ||, but ShellCheck cannot accept a function there.
try() {
  set +e
  "$@"
  status=$?
  set -e
}

# One line per file: checksum, modification time (seconds) and mode. With the argument
# content the modification time is left out, because a restored file is new on purpose.
state() {
  for f in $files; do
    [ -f "$f" ] || { echo "$f missing"; continue; }
    st_sum=$(sha256sum "$f")
    st_sum=${st_sum%% *}
    st_mode=$(stat -c %a "$f")
    if [ "${1:-}" = content ]; then
      echo "$f $st_sum $st_mode"
    else
      st_time=$(stat -c %Y "$f")
      echo "$f $st_sum $st_time $st_mode"
    fi
  done
}

no_temp_files() {
  for d in $tmpdirs; do
    # find fails when the folder does not exist, and then there is no temporary file in it.
    st_found=$(find "$d" -maxdepth 1 -name '*.new' 2>/dev/null) || st_found=
    if [ -n "$st_found" ]; then
      fail "temporary file left in $d"
    fi
  done
}

# cmp is missing on some minimal images, so files are compared by checksum. The third
# argument is the failure message.
expect_same_file() {
  sf_first=$(sha256sum < "$1") || fail "$3"
  sf_second=$(sha256sum < "$2") || fail "$3"
  [ "$sf_first" = "$sf_second" ] || fail "$3"
}

# Runs the setup script, keeps its output in $out and echoes it, and returns its status.
run_script() {
  rc=0
  sh /site/setup.sh "$@" >"$out" 2>&1 || rc=$?
  cat "$out"
  return "$rc"
}

# The file only exists on the system under test.
# shellcheck disable=SC1091
pretty=$( . /etc/os-release >/dev/null 2>&1; printf %s "${PRETTY_NAME:-$format}" )

# The commands the script printed under "Next:", one per line: sudo removed because this
# container runs as root, the trailing comment removed, blank lines dropped. The test runs
# these lines instead of its own copy, so it proves that what people are told to run works.
next_commands() {
  sed -n '/^The SpliceFS package repository is set up\. Next:$/,$p' "$1" | sed '1d' |
    sed -e 's/#.*$//' -e 's/^ *//' -e 's/ *$//' -e 's/^sudo //' -e '/^$/d'
}

# Answers the one question the printed commands ask (continue? import a key?), as a person
# would at the prompt. The commands carry no -y flag on purpose. Three tools refuse to take
# answers from anything but a terminal, which a test does not have: zypper always, and dnf
# and yum on the oldest supported systems when a key has to be imported. Those get their own
# switch for running without a terminal, which gives the answers a person would give.
run_printed() {
  echo "+ $1"
  case "$1" in
    "zypper "*) sh -c "zypper --non-interactive ${1#zypper }" ;;
    "dnf "* | "yum "*) sh -c "${1%% *} -y ${1#* }" ;;
    *) yes | sh -c "$1" ;;
  esac
}

# a. apt needs the certificate bundle for https sources, and the script refuses before it
# writes anything when it is missing. The bundle is moved away on systems that have it, so
# every apt system proves the refusal.
if [ "$format" = deb ]; then
  bundle=/etc/ssl/certs/ca-certificates.crt
  moved=0
  if [ -f "$bundle" ]; then
    mv "$bundle" "$bundle.aside"
    moved=1
  fi
  try run_script
  [ "$status" -eq 1 ] || fail "setup.sh without ca-certificates exited $status, expected 1"
  grep -q 'ca-certificates' "$out" || fail "the refusal does not name ca-certificates"
  [ ! -e "$keyfile" ] && [ ! -e "$srcfile" ] || fail "the refusal wrote a file"
  if [ "$moved" -eq 1 ]; then
    mv "$bundle.aside" "$bundle"
  else
    # A bare image has no bundle. This is the step the refusal tells a person to take.
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates
  fi
fi

# b. argument errors exit 2 and touch nothing, before the first setup and after it
for arg in both nonsense; do
  try run_script "$arg"
  [ "$status" -eq 2 ] || fail "setup.sh $arg exited $status, expected 2"
  grep -q '^usage: sh setup.sh$' "$out" || fail "setup.sh $arg did not print the usage line"
done
for f in $files; do
  [ ! -e "$f" ] || fail "an argument error wrote $f"
done

# c. the script succeeds and prints the next steps
try run_script
[ "$status" -eq 0 ] || fail "setup.sh exited $status"
cp "$out" "$first"
grep -q '^The SpliceFS package repository is set up\. Next:$' "$first" ||
  fail "setup.sh did not print the next steps"

# d. files, modes, no temporary files
for f in $files; do
  [ -f "$f" ] || fail "$f was not written"
  mode=$(stat -c %a "$f")
  [ "$mode" = 644 ] || fail "$f has mode $mode, expected 644"
done
expect_same_file "$keyfile" "$sitekey" "$keyfile differs from the published key"
no_temp_files
before=$(state)
before_content=$(state content)

# e. the script installed nothing
for p in splicefs-server splicefs-client; do
  try is_installed "$p"
  [ "$status" -ne 0 ] || fail "setup.sh installed $p"
done
if command -v splicefsd >/dev/null 2>&1 || command -v splicefs >/dev/null 2>&1; then
  fail "a SpliceFS program is on the system after setup.sh"
fi

# f. argument errors after setup change nothing
sleep 1
for arg in both nonsense; do
  try run_script "$arg"
  [ "$status" -eq 2 ] || fail "setup.sh $arg exited $status after setup, expected 2"
done
now=$(state)
[ "$now" = "$before" ] || fail "an argument error changed a file"

# g. a second run changes nothing, not even a modification time. The sleep makes a rewrite
# visible, because mtime has one second resolution on some filesystems.
sleep 2
try run_script
[ "$status" -eq 0 ] || fail "second setup.sh exited $status"
if grep -q '^updated ' "$out"; then fail "second run printed an updated line"; fi
now=$(state)
[ "$now" = "$before" ] || fail "second run changed a file (checksum, mtime or mode)"
no_temp_files
cmds_again=$(next_commands "$out")
cmds_first=$(next_commands "$first")
[ "$cmds_again" = "$cmds_first" ] ||
  fail "second run printed other next steps than the first"

# h. repair: a deleted key and a damaged source file come back, and only those two are
# reported
rm -f "$keyfile"
echo "junk line" >>"$srcfile"
try run_script
[ "$status" -eq 0 ] || fail "repair run exited $status"
# grep -c exits 1 when it counts zero lines, and the count it prints is the answer.
updated_count=$(grep -c '^updated ' "$out") || true
[ "$updated_count" -eq 2 ] || fail "repair run did not print exactly two updated lines"
grep -q "^updated $keyfile\$" "$out" || fail "repair run did not report $keyfile"
grep -q "^updated $srcfile\$" "$out" || fail "repair run did not report $srcfile"
expect_same_file "$keyfile" "$sitekey" "$keyfile was not restored"
# Checksum and mode only: the restored files are new, so their mtime differs on purpose.
restored=$(state content)
[ "$restored" = "$before_content" ] ||
  fail "files are not back to their original content and mode"
no_temp_files

# i. the commands the script printed: first the index refresh, then the server, then the client
cmds=$(next_commands "$first")
cmd_count=$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')
[ "$cmd_count" = 3 ] ||
  fail "expected 3 printed commands (refresh, server, client), got: $cmds"
refresh_cmd=$(printf '%s\n' "$cmds" | sed -n 1p)
server_cmd=$(printf '%s\n' "$cmds" | sed -n 2p)
client_cmd=$(printf '%s\n' "$cmds" | sed -n 3p)
case "$server_cmd" in *" splicefs-server") ;; *) fail "second printed command is not the server install: $server_cmd" ;; esac
case "$client_cmd" in *" splicefs-client") ;; *) fail "third printed command is not the client install: $client_cmd" ;; esac
try run_printed "$refresh_cmd"
[ "$status" -eq 0 ] || fail "printed refresh command failed: $refresh_cmd"
try run_printed "$server_cmd"
[ "$status" -eq 0 ] || fail "printed server command failed: $server_cmd"
try run_printed "$client_cmd"
[ "$status" -eq 0 ] || fail "printed client command failed: $client_cmd"

# j. both packages are installed and both programs report a version
for p in splicefs-server splicefs-client; do
  try is_installed "$p"
  [ "$status" -eq 0 ] || fail "$p is not installed according to the package manager"
done
splicefsd --version | grep -q . || fail "splicefsd --version printed nothing"
splicefs --version | grep -q . || fail "splicefs --version printed nothing"

# k. the package manager can remove what the printed commands installed
try remove_pkgs splicefs-server splicefs-client
[ "$status" -eq 0 ] || fail "removing the packages failed"
for p in splicefs-server splicefs-client; do
  try is_installed "$p"
  [ "$status" -ne 0 ] || fail "$p is still installed after removal"
done

echo "setup test passed on $pretty"
