#!/bin/sh
# Tests of "setup.sh --remove" for every package family, against a fake root. Runs on the host,
# needs no root and no container (part of make check).
# The built script cannot run as a whole here: it needs root and the real package manager. So its
# last line, the call of main, is cut off, and every path that points into the system gets the
# fake root in front of it. Then the functions that main calls for one family are called
# directly. A fake rpm keeps its database in a folder of the fake root, so the key that
# "rpm --import" adds is part of what is compared.
set -u

cd "$(dirname "$0")/.." || exit 1
script=dist/site/setup.sh
[ -f "$script" ] || { echo "run make site first" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
root=$TMP/root
FAILS=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

# Only a top-level assignment of an absolute path gets the root, and PATH is not one. A path
# the rewrite missed would make the test touch the real system, so the test stops when one is
# left.
sed -e '/^PATH=/!s|^\([A-Z_]*\)=/|\1='"$root"'/|' -e '$d' "$script" > "$TMP/lib.sh"
unmoved=$(grep -E '^[A-Z_]+=/' "$TMP/lib.sh" | grep -v -e '^PATH=' -e "=$root/")
if [ -n "$unmoved" ] || ! grep -q "^APT_KEY=$root/" "$TMP/lib.sh" || grep -q '^main "\$@"$' "$TMP/lib.sh"; then
  echo "FAIL the script could not be moved into the fake root: $unmoved" >&2
  exit 1
fi

mkdir "$TMP/bin"
cat > "$TMP/bin/rpm" <<'RPM'
#!/bin/sh
# One file in $RPMDB for each key, named as rpm names it. Every call is logged.
echo "$*" >> "$RPMLOG"
case "$1" in
  --import)
    mkdir -p "$RPMDB"
    cp "$2" "$RPMDB/gpg-pubkey-$(cksum < "$2" | cut -d' ' -f1)-0"
    ;;
  -qa) ls "$RPMDB" 2>/dev/null || true ;;
  -q)
    # Like rpm, the description is the key with a line of rpm's own added to the armor.
    head -n 1 "$RPMDB/$4"
    echo "Version: fake rpm"
    tail -n +2 "$RPMDB/$4"
    ;;
  -e) rm "$RPMDB/$2" ;;
  *) echo "fake rpm: $*" >&2; exit 1 ;;
esac
RPM
chmod 755 "$TMP/bin/rpm"
export RPMDB=$root/rpmdb RPMLOG=$TMP/rpm.log FAKEBIN=$TMP/bin

# Runs a function of the script, with the fake rpm first on the PATH. The script sets its own
# PATH when it is sourced, so the fake is put in front afterwards.
run_fn() {
  RC=0
  sh -c '. "$1"; PATH=$FAKEBIN:$PATH; shift; "$@"' sh "$TMP/lib.sh" "$@" > "$TMP/out" 2>&1 || RC=$?
}
var_of() {
  sh -c '. "$1"; eval "printf %s \"\${$2}\""' sh "$TMP/lib.sh" "$1"
}

# One line for each file: path, checksum, mode. With "all" the folders are listed too.
snap() {
  if [ "${1:-}" = all ]; then
    (cd "$root" && find . | LC_ALL=C sort)
    return 0
  fi
  (cd "$root" && find . -type f | LC_ALL=C sort | while read -r f; do
    printf '%s %s %s\n' "$f" "$(cksum < "$f")" "$(ls -l "$f" | cut -c1-10)"
  done)
}

# A root as a system has it: the folders exist and hold files of other makers, and rpm knows a
# key of another maker. Setup and removal must leave all of that as it is.
fresh_root() {
  rm -rf "$root" "$RPMLOG"
  mkdir -p "$root/rpmdb"
  : > "$RPMLOG"
  for p in "$key" "$repo"; do
    mkdir -p "$(dirname "$p")"
    echo "not ours: $p" > "$(dirname "$p")/other-file"
  done
  printf '%s\n\n%s\n%s\n%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'Zm9yZWlnbg==' '=abcd' \
    '-----END PGP PUBLIC KEY BLOCK-----' > "$root/rpmdb/gpg-pubkey-deadbeef-0"
}

# expect NAME CONDITION...: the condition is a command that must succeed.
expect() {
  name=$1
  shift
  if "$@"; then pass "$fam: $name"; else fail "$fam: $name"; sed 's/^/        /' "$TMP/out"; fi
}
same() { [ "$1" = "$2" ]; }
ok() { [ "$RC" -eq 0 ]; }
quiet() { ok && [ ! -s "$TMP/out" ]; }
says() { grep -q -e "$1" "$TMP/out"; }
db_keys() { ls "$root/rpmdb" | tr '\n' ' '; }
erase_calls() { grep -c '^-e ' "$RPMLOG" || true; }

# The setup and removal of one family. Arguments: family, the variable that holds the key's
# path, the variable that holds the repository file's path, whether rpm holds the key.
check_family() {
  fam=$1
  key=$(var_of "$2")
  repo=$(var_of "$3")
  rpmkey=$4

  fresh_root
  before=$(snap)
  run_fn "setup_$fam"
  expect "setup exits 0" ok
  expect "setup writes the key and the repository" test -f "$key" -a -f "$repo"
  expect "setup changes the root" test "$(snap)" != "$before"
  run_fn "remove_$fam"
  expect "removal exits 0" ok
  expect "removal reports the repository file" says "^removed $repo\$"
  expect "removal reports the key file" says "^removed $key\$"
  expect "setup then removal leaves every file and its content as it was" same "$(snap)" "$before"
  if [ "$rpmkey" = rpm ]; then
    expect "the key is out of rpm and the other key is still there" same "$(db_keys)" 'gpg-pubkey-deadbeef-0 '
    expect "rpm erased one key and no other package" same "$(erase_calls)" 1
  fi
  run_fn "remove_$fam"
  expect "a second removal prints nothing and changes nothing" quiet
  expect "a second removal leaves the root as it was" same "$(snap)" "$before"

  rm -rf "$root"
  mkdir "$root"
  run_fn "remove_$fam"
  expect "removal on a clean root prints nothing" quiet
  expect "removal on a clean root creates nothing" same "$(snap all)" '.'

  for changed in repo key; do
    fresh_root
    run_fn "setup_$fam"
    eval "file=\$$changed"
    echo '# the person changed this' >> "$file"
    kept=$(cat "$file")
    run_fn "remove_$fam"
    expect "removal exits 0 although a file is kept" ok
    expect "a changed $changed file is kept as it is" same "$(cat "$file")" "$kept"
    expect "a changed $changed file gets a warning that names it" says "warning: $file"
    if [ "$changed" = repo ]; then other=$key; else other=$repo; fi
    expect "the other file is still removed after a changed $changed file" test ! -e "$other"
    expect "the files of other makers stay" same "$(find "$root" -name other-file | wc -l | tr -d ' ')" 2
  done
}

check_family apt APT_KEY APT_REPO none
check_family dnf RPM_KEY DNF_REPO rpm
check_family zypper RPM_KEY ZYPPER_REPO rpm
check_family apk APK_KEY APK_REPO none
check_family pkg PKG_KEY PKG_REPO none

if [ "$FAILS" -eq 0 ]; then
  echo "setup-remove-test: all passed"
else
  echo "setup-remove-test: $FAILS failed"
  exit 1
fi
