#!/bin/sh
# The job of the FreeBSD test (tests/freebsd.sh). FreeBSD runs it once, as root, at the end
# of its first boot, started by the first-boot script packaging/freebsd/user-data.in.
#
# The contract:
# - The input archive is the machine's fourth disk (/dev/vtbd3). The job unpacks it into
#   /tmp/input first, and from then on the site is at /tmp/input/site. It was built for the
#   base address file:///tmp/input/site, so the setup script reads its own hash from there.
# - The job runs as root.
# - Everything it prints (standard output and standard error) comes back to the host.
# - Its last line must be FREEBSD-SETUP-OK when all checks passed.
#
# It tests the setup script on FreeBSD: the refusals first, then the real run, then a
# second run, and last the installation of both packages from the published repositories.
# There is no set -e: a failed check is printed as FAIL and the job goes on, so one run
# shows every problem. The end line says whether anything failed.

# The packages and pkg itself, once bootstrapped, live under /usr/local.
PATH=/usr/local/sbin:/usr/local/bin:$PATH
export PATH

mkdir -p /tmp/input
tar -xf /dev/vtbd3 -C /tmp/input || { echo "FAIL: cannot read the input archive"; exit 1; }

site=/tmp/input/site
setup=$site/setup.sh
keyfile=/usr/local/etc/pkg/keys/splicefs.rsa.pub
repofile=/usr/local/etc/pkg/repos/splicefs.conf
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

heading "e. the real run"
run_sh "$setup"
expect_status 0 "the real run"
cmp -s "$site/keys/splicefs.rsa.pub" "$keyfile" || note_fail "$keyfile is not the published key"
for word in splicefs-server splicefs-client 'signature_type: "pubkey"' 'file:///tmp/input/site'; do
  grep -q -F -e "$word" "$repofile" || note_fail "$repofile does not contain '$word'"
done
# pkg fills in the ABI itself, so the file must keep the text, once per repository.
abi_count=$(grep -c -F -e "\${ABI}" "$repofile") || abi_count=0
[ "$abi_count" -eq 2 ] || note_fail "$repofile has \${ABI} in $abi_count lines, expected 2"
expect_output 'pkg update' "the real run"
expect_output 'pkg install splicefs-server' "the real run"
expect_output 'pkg install splicefs-client' "the real run"

heading "f. a second run rewrites nothing"
run_sh "$setup"
expect_status 0 "the second run"
if grep -q '^updated' "$out"; then
  note_fail "the second run rewrote a file"
fi

# Until here the repositories were the site folder inside the machine. The published
# repositories must verify with the key the script installed, so they are used from here on.
heading "g. install both packages from the published repositories"
sed -i '' "s|file:///tmp/input/site|$published_url|g" "$repofile" || note_fail "cannot change the base address"
grep -q -F -e "$published_url" "$repofile" || note_fail "$repofile does not name $published_url"
if grep -q -F -e 'file://' "$repofile"; then
  note_fail "$repofile still reads from a folder, so the published repositories would not be tested"
fi
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

heading "h. installed packages"
# pkg info prints the name and version fields only for a single package, so the two are
# asked for with pkg query, one line each.
installed="$(pkg query '%n %v' splicefs-server splicefs-client 2>&1)"
echo "$installed"
case "$installed" in
  *splicefs-server*splicefs-client* | *splicefs-client*splicefs-server*) ;;
  *) note_fail "pkg query does not list both SpliceFS packages" ;;
esac

if [ "$failed" -ne 0 ]; then
  echo FREEBSD-SETUP-FAILED
  exit 1
fi
echo FREEBSD-SETUP-OK
