#!/bin/sh
# The job of the FreeBSD test (tests/freebsd.sh). FreeBSD runs it once, as root, at the end
# of its first boot, started by the first-boot script of the machine image (/freebsd/user-data.in in the image).
#
# The contract:
# - The input archive is the machine's fourth disk (/dev/vtbd3). The job unpacks it into
#   /tmp/input first, and from then on the site is at /tmp/input/site: the published setup
#   script and the keys of the repository. The script's base address is the published site,
#   which its self-check reads on the web.
# - The job runs as root.
# - Everything it prints (standard output and standard error) comes back to the host.
# - Its last line must be FREEBSD-SETUP-OK when all checks passed.
#
# It tests the setup script on FreeBSD: the refusals first, then the real run, then a
# second run, and last the installation of both packages from the published repositories.
# There is no set -e: a failed check is printed as FAIL and the job goes on, so one run
# shows every problem. The end line says whether anything failed. The one exception is the
# preparation of the machine at the start: when FreeBSD's server cannot be reached the job
# stops there, because nothing after it would say anything about the setup script.

# The packages and pkg itself, once bootstrapped, live under /usr/local.
PATH=/usr/local/sbin:/usr/local/bin:$PATH
export PATH

mkdir -p /tmp/input
tar -xf /dev/vtbd3 -C /tmp/input || { echo "FAIL: cannot read the input archive"; exit 1; }

site=/tmp/input/site
setup=$site/setup.sh
keyfile=/usr/local/etc/pkg/keys/splicefs.rsa.pub
repofile=/usr/local/etc/pkg/repos/splicefs.conf
setup_dirs="/usr/local/etc/pkg/keys /usr/local/etc/pkg/repos /usr/local/etc/pkg"
published_url=https://packages.splicefs.org
failed=0
status=0
out=$(mktemp /tmp/setup-out.XXXXXX)
work=$(mktemp -d /tmp/setup-work.XXXXXX)
trap 'rm -rf "$out" "$work"' EXIT

release=$(uname -r)
echo "FreeBSD $release"
ls -l "$site"

heading() {
  echo
  echo "== $* =="
}

note_fail() {
  echo "FAIL: $*"
  failed=1
}

# retry <tries> <pause seconds> <failure message> <command> [argument ...]
# Runs the command up to <tries> times and stops at the first success. It pauses between the
# tries, not after the last, and prints the failure message when the last try failed. For work
# that depends on a server this project does not run, and nothing else. Tested on the host by
# scripts/freebsd-retry-test.sh, which reads this function from here.
retry() {
  retry_tries="$1"
  retry_pause="$2"
  retry_message="$3"
  shift 3
  retry_try=1
  until "$@"; do
    if [ "$retry_try" -ge "$retry_tries" ]; then
      echo "FAIL: $retry_message after $retry_try tries"
      return 1
    fi
    echo "try $retry_try of $retry_tries failed, trying again in $retry_pause seconds: $*"
    retry_try=$((retry_try + 1))
    sleep "$retry_pause"
  done
}

# Runs the shell on the given script and arguments. The output is kept in $out and shown,
# and the exit status is left in $status, because a refusal is an answer to check here.
run_sh() {
  status=0
  sh "$@" >"$out" 2>&1 || status=$?
  cat "$out"
}

expect_status() {
  [ "$status" -eq "$1" ] || note_fail "$2 exited $status, expected $1"
}

# The pattern is plain text, not a regular expression.
expect_output() {
  grep -q -F -e "$1" "$out" || note_fail "$2: the output does not contain '$1'"
}

# A refused run must leave the system alone, so neither file the script writes may exist.
expect_no_files() {
  for f in "$keyfile" "$repofile"; do
    [ ! -e "$f" ] || note_fail "$1 wrote $f"
  done
}

# The folders the setup writes into (the keys and the repository files of pkg), as they are now:
# one line each, with the names in it or "missing". A folder the setup made is missing again
# after --remove, and a folder the system ships keeps what it held.
layout() {
  for d in $setup_dirs; do
    if [ -d "$d" ]; then
      lay_names=$(find "$d" -maxdepth 1 ! -path "$d" | sed "s|^$d/||" | sort | tr '\n' ' ')
      echo "$d: $lay_names"
    else
      echo "$d: missing"
    fi
  done
}

# Whether pkg reads the repository of the setup: "pkg -vv" prints every repository it knows.
repo_listed() {
  pkg -vv 2>/dev/null | grep -q -F -e splicefs-server
}

# On a system the script has not touched, --remove has nothing to do and says nothing is wrong.
check_remove_clean() {
  run_sh "$setup" --remove
  expect_status 0 "--remove on a clean system"
  if grep -q -e '^removed ' -e '^warning:' "$out"; then note_fail "--remove on a clean system removed or warned"; fi
  expect_no_files "--remove on a clean system"
}

# --remove takes the repository file and the key away and no package, and leaves the folders as they
# were before the setup. $1 is the layout then, $2 a changed copy of the script, which is refused
# for --remove as for the setup. pkg must list the repository before, which proves the check, and
# not after.
check_remove() {
  cr_layout="$1"
  run_sh "$2" --remove
  expect_status 1 "a changed copy with --remove"
  expect_output 'does not match the published one' "a changed copy with --remove"
  for f in "$keyfile" "$repofile"; do
    [ -f "$f" ] || note_fail "a changed copy with --remove removed $f"
  done
  repo_listed || note_fail "pkg does not list the repository before --remove"
  cp "$keyfile" "$work/key.before"
  cp "$repofile" "$work/repo.before"
  run_sh "$setup" --remove
  expect_status 0 "--remove"
  for f in "$keyfile" "$repofile"; do
    [ ! -e "$f" ] || note_fail "--remove left $f"
    grep -q -x -F -e "removed $f" "$out" || note_fail "--remove did not report $f"
  done
  if repo_listed; then note_fail "pkg still lists the repository after --remove"; fi
  cr_after="$(layout)"
  [ "$cr_after" = "$cr_layout" ] || note_fail "after --remove the folders are not as they were before the setup. Before:
$cr_layout
After:
$cr_after"
  # The packages are still installed, and the script says how to remove them.
  for p in splicefs-server splicefs-client; do
    pkg info -e "$p" || note_fail "--remove removed $p"
    expect_output "pkg delete $p" "--remove (the command that removes $p)"
  done
  # A second run has nothing left to do and is quiet.
  run_sh "$setup" --remove
  expect_status 0 "a second --remove"
  if grep -q -e '^removed ' -e '^warning:' "$out"; then note_fail "second --remove removed or warned"; fi
  # The setup after a removal gives back the same files.
  run_sh "$setup"
  expect_status 0 "the setup after --remove"
  cmp -s "$work/key.before" "$keyfile" || note_fail "the setup after --remove did not restore $keyfile"
  cmp -s "$work/repo.before" "$repofile" || note_fail "the setup after --remove did not restore $repofile"
}

# The first pkg command on a new machine finds pkg itself old, upgrades it and refreshes the
# catalogs of FreeBSD, all from FreeBSD's own server, which is sometimes slow. That says
# nothing about the setup script, so the machine is prepared here, with tries, before the setup
# script is started. The setup script runs only after this returned success, and runs once.
prepare_pkg() {
  env ASSUME_ALWAYS_YES=yes pkg update -f && env ASSUME_ALWAYS_YES=yes pkg upgrade -y pkg
}
heading "prepare. refresh the catalogs of FreeBSD and upgrade pkg"
retry 3 5 "FreeBSD's package server (pkg.FreeBSD.org) did not answer, so pkg could not be prepared and the setup script was not run" prepare_pkg || {
  echo FREEBSD-SETUP-FAILED
  exit 1
}

heading "a. a changed copy is refused"
cp "$setup" "$work/changed.sh"
echo '# changed' >>"$work/changed.sh"
run_sh "$work/changed.sh"
expect_status 1 "a changed copy"
expect_output 'does not match the published one' "a changed copy"
expect_output 'fetch -o' "a changed copy"
expect_no_files "a changed copy"

heading "b. a copy without its last line does nothing"
sed '$d' "$setup" >"$work/cut.sh"
run_sh "$work/cut.sh"
expect_no_files "a copy without its last line"

heading "c. a script piped into a shell is refused"
status=0
sh <"$setup" >"$out" 2>&1 || status=$?
cat "$out"
expect_status 1 "a script piped into a shell"
expect_output 'run from a file' "a script piped into a shell"
expect_no_files "a script piped into a shell"

heading "d. an argument is refused"
run_sh "$setup" server
expect_status 2 "an argument"
expect_output 'usage' "an argument"
expect_no_files "an argument"

heading "e. --remove on a system the script has not touched"
check_remove_clean
layout_before="$(layout)"

heading "f. the real run"
run_sh "$setup"
expect_status 0 "the real run"
cmp -s "$site/keys/splicefs.rsa.pub" "$keyfile" || note_fail "$keyfile is not the published key"
for word in splicefs-server splicefs-client 'signature_type: "pubkey"' "$published_url"; do
  grep -q -F -e "$word" "$repofile" || note_fail "$repofile does not contain '$word'"
done
# pkg fills in the ABI itself, so the file must keep the text, once per repository.
abi_count=$(grep -c -F -e "\${ABI}" "$repofile") || abi_count=0
[ "$abi_count" -eq 2 ] || note_fail "$repofile has \${ABI} in $abi_count lines, expected 2"
expect_output 'pkg update' "the real run"
expect_output 'pkg install splicefs-server' "the real run"
expect_output 'pkg install splicefs-client' "the real run"

heading "g. a second run rewrites nothing"
run_sh "$setup"
expect_status 0 "the second run"
if grep -q '^updated' "$out"; then
  note_fail "the second run rewrote a file"
fi

# The published repositories must verify with the key the script installed.
heading "h. install both packages from the published repositories"
# Without this pkg asks before it sets itself up on a new system.
ASSUME_ALWAYS_YES=yes
export ASSUME_ALWAYS_YES
pkg update || note_fail "pkg update failed"
pkg install -y splicefs-server splicefs-client || note_fail "pkg install failed"
for prog in splicefsd splicefs; do
  version=$("$prog" --version 2>&1) || version=
  if [ -z "$version" ]; then
    note_fail "$prog --version did not print a version"
  else
    echo "$prog --version: $version"
  fi
done

heading "i. installed packages"
# pkg info prints the name and version fields only for a single package, so the two are
# asked for with pkg query, one line each.
installed="$(pkg query '%n %v' splicefs-server splicefs-client 2>&1)"
echo "$installed"
case "$installed" in
  *splicefs-server*splicefs-client* | *splicefs-client*splicefs-server*) ;;
  *) note_fail "pkg query does not list both SpliceFS packages" ;;
esac

heading "j. --remove takes the repository and the key away and no package"
check_remove "$layout_before" "$work/changed.sh"

heading "k. the package manager removes what the printed commands installed"
pkg delete -y splicefs-server splicefs-client || note_fail "pkg delete failed"
for p in splicefs-server splicefs-client; do
  if pkg info -e "$p"; then note_fail "$p is still installed after pkg delete"; fi
done

if [ "$failed" -ne 0 ]; then
  echo FREEBSD-SETUP-FAILED
  exit 1
fi
echo FREEBSD-SETUP-OK
