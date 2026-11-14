#!/bin/sh
# Checks the repository and the built site. Run through "make check", which builds first.
# Needs python3 (standard library only). Uses node, dash and bash when they exist.
set -u

cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP  $1"; }
# Runs a command quietly and reports its result under a name; output is kept for failures.
run() {
  name=$1
  shift
  if "$@" > "$TMP/out" 2>&1; then
    pass "$name"
  else
    fail "$name"
    sed 's/^/        /' "$TMP/out"
  fi
}

[ -f dist/site/setup.sh ] || { echo "run make site first" >&2; exit 1; }

# 1. Plain ASCII everywhere, and no private names. The names are assembled from pieces so
# this file does not trip its own check.
cat > "$TMP/ascii.py" <<'PYEOF'
import os, sys
names = [a + b for a, b in (("blue", "rival"), ("blue", "xd"), ("hil", "doer"),
                            ("pho", "enix"), ("new-", "york"), ("castle-", "rock"))]
skip_dirs = {".git", "keys", "dist"}
files = []
for root, dirs, fs in os.walk("."):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for f in fs:
        # In a second working copy of the repository .git is a file that holds a folder
        # path of the machine; like the .git folder it is not part of the project.
        if root == "." and f in ("LICENSE", ".git"):
            continue
        files.append(os.path.join(root, f))
files += ["dist/site/setup.sh", "dist/site/index.html", "dist/site/setup.sh.sha256"]
bad = 0
for path in sorted(files):
    data = open(path, "rb").read()
    for i, b in enumerate(data):
        if b > 127:
            print("non-ASCII byte in %s at offset %d" % (path, i)); bad += 1; break
    low = data.lower()
    for n in names:
        if n.encode() in low:
            print("forbidden name in %s" % path); bad += 1
sys.exit(1 if bad else 0)
PYEOF
run "1. ASCII only and no forbidden names" python3 -I "$TMP/ascii.py"

# 2. Syntax of every shell file with every shell that exists.
for f in setup.sh.in dist/site/setup.sh steps/*.sh scripts/*.sh; do
  run "2. sh -n $f" sh -n "$f"
  command -v dash >/dev/null 2>&1 && run "2. dash -n $f" dash -n "$f"
  command -v bash >/dev/null 2>&1 && run "2. bash -n $f" bash -n "$f"
done

# 3. The page's code blocks against the step files and the one-command forms.
cat > "$TMP/blocks.py" <<'PYEOF'
import html, json, re, sys
page = open("site/index.html", encoding="ascii").read()
blocks = [html.unescape(b) for b in re.findall(r"<pre><code>(.*?)</code></pre>", page, re.S)]
json.dump(blocks, open(sys.argv[1], "w"))
step = {k: open("steps/%s.sh" % k).read() for k in ("apt", "dnf", "zypper", "apk", "pkg")}
base = "https://packages.splicefs.org"
curl = "curl --proto '=https' --tlsv1.2 -fsSL %s/setup.sh -o ~/splicefs-setup.sh &&\n  sudo sh ~/splicefs-setup.sh\n" % base
wget = "wget -qO ~/splicefs-setup.sh %s/setup.sh &&\n  sudo sh ~/splicefs-setup.sh\n" % base
fetch = "fetch -o ~/splicefs-setup.sh %s/setup.sh &&\n  sh ~/splicefs-setup.sh\n" % base
# Each step file already ends with the update and install commands, so a family is one block.
expected = [curl, wget, fetch, "sha256sum ~/splicefs-setup.sh\n"] + [step[k] for k in ("apt", "dnf", "zypper", "apk", "pkg")]
bad = 0
if len(blocks) != len(expected):
    print("page has %d code blocks, expected %d" % (len(blocks), len(expected))); bad += 1
for i, (got, want) in enumerate(zip(blocks, expected)):
    if got != want:
        print("block %d differs from its source" % (i + 1)); bad += 1
sys.exit(1 if bad else 0)
PYEOF
run "3. page code blocks match steps/ and the setup lines" python3 -I "$TMP/blocks.py" "$TMP/blocks.json"

# 4. The built script: keys byte-identical, no placeholder left, last line, checksum.
cat > "$TMP/built.py" <<'PYEOF'
import hashlib, re, sys
s = open("dist/site/setup.sh", encoding="ascii").read()
bad = 0
for key in ("keys/splicefs.asc", "keys/splicefs.rsa.pub"):
    k = open(key, encoding="ascii").read()
    if ("<<'KEY_EOF'\n" + k + "KEY_EOF\n") not in s:
        print("%s is not embedded byte for byte" % key); bad += 1
if re.search(r"@[A-Z_]+@", s):
    print("placeholder left in setup.sh"); bad += 1
# pkg expands the ABI variable itself, so it must reach the file unexpanded: once per repository.
if s.count("${ABI}") != 2:
    print("setup.sh holds the text ${ABI} %d times, expected 2" % s.count("${ABI}")); bad += 1
for name in ("splicefs-server: {", "splicefs-client: {"):
    if name not in s:
        print("setup.sh does not write the repository %s" % name); bad += 1
if not s.endswith('\nmain "$@"\n'):
    print('last line is not main "$@"'); bad += 1
want = hashlib.sha256(open("dist/site/setup.sh", "rb").read()).hexdigest() + "  setup.sh\n"
if open("dist/site/setup.sh.sha256").read() != want:
    print("setup.sh.sha256 does not match"); bad += 1
sys.exit(1 if bad else 0)
PYEOF
run "4. built setup.sh: keys, placeholders, last line, sha256" python3 -I "$TMP/built.py"

# 5. The page script and its tokenizer.
cat > "$TMP/tok.js" <<'JSEOF'
const fs = require('fs'), vm = require('vm');
const page = fs.readFileSync('site/index.html', 'utf8');
const code = page.match(/<script>([\s\S]*?)<\/script>/)[1];
fs.writeFileSync(process.argv[3], code);
const mod = { exports: {} };
vm.runInNewContext(code, { module: mod });
const blocks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let bad = 0;
blocks.forEach((b, i) => {
  const joined = mod.exports.tokenize(b).map((t) => t.s).join('');
  if (joined !== b) { console.log('block ' + (i + 1) + ' does not round-trip'); bad++; }
});
const kinds = new Set();
blocks.forEach((b) => mod.exports.tokenize(b).forEach((t) => kinds.add(t.t)));
if (!kinds.has('cmt')) { console.log('no comment token produced'); bad++; }
process.exit(bad ? 1 : 0);
JSEOF
if command -v node >/dev/null 2>&1; then
  run "5. tokenizer reproduces every block" node "$TMP/tok.js" "$TMP/blocks.json" "$TMP/page.js"
  run "5. node --check on the page script" node --check "$TMP/page.js"
else
  skip "5. node is not on the PATH, tokenizer and page script not checked"
fi

# 6. Script behavior that needs no root and no container. A fake id stands in for a user.
mkdir "$TMP/bin"
printf '#!/bin/sh\necho 1000\n' > "$TMP/bin/id"
chmod 755 "$TMP/bin/id"
expect() {
  name=$1
  want=$2
  needle=$3
  shift 3
  PATH="$TMP/bin:$PATH" "$@" > "$TMP/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ] && grep -q "$needle" "$TMP/out"; then
    pass "$name"
  else
    fail "$name (exit $got, wanted $want)"
    sed 's/^/        /' "$TMP/out"
  fi
}
# No argument gets as far as the root check, and any argument is refused before it.
expect "6. no argument, not root: message, exit 1" 1 "run this script as root, for example with sudo" \
  sh dist/site/setup.sh
expect "6. an argument: usage, exit 2" 2 "usage: sh setup.sh" sh dist/site/setup.sh server
expect "6. an argument: says it only sets up the repository, exit 2" 2 \
  "only sets up the package repository" sh dist/site/setup.sh nonsense

# The next-step lines are printed by one function, taken out of the built script and run for
# each family. The script itself cannot run here, because it writes under /etc as root.
awk '/^next_steps\(\) \{$/ { on = 1 } on { print } on && /^\}$/ { exit }' dist/site/setup.sh \
  > "$TMP/next.sh"
next_text() {
  printf 'The SpliceFS package repository is set up. Next:\n\n  %s %s\n  %s %s splicefs-server    # the server\n  %s %s splicefs-client    # the client\n' \
    "$1" "$2" "$1" "$3" "$1" "$3"
}
# Arguments: family, rpm tool, the printed manager, update word, install word, step file.
expect_next() {
  next_text "$3" "$4" "$5" > "$TMP/want"
  FAMILY=$1 RPM_TOOL=$2 sh -c '. "$1"; next_steps' sh "$TMP/next.sh" > "$TMP/got" 2>&1
  if cmp -s "$TMP/want" "$TMP/got"; then
    pass "6. next steps for $1 ($3 $4)"
  else
    fail "6. next steps for $1 ($3 $4)"
    diff "$TMP/want" "$TMP/got" | sed 's/^/        /'
  fi
  # The manual steps on the page must end with the same three command lines.
  if [ -n "${6:-}" ]; then
    tail -n 3 "$TMP/want" | sed 's/^  //' > "$TMP/want3"
    tail -n 3 "steps/$6.sh" > "$TMP/got3"
    if cmp -s "$TMP/want3" "$TMP/got3"; then
      pass "6. steps/$6.sh ends with the lines the script prints"
    else
      fail "6. steps/$6.sh ends with the lines the script prints"
      diff "$TMP/want3" "$TMP/got3" | sed 's/^/        /'
    fi
  fi
}
expect_next apt '' 'sudo apt-get' update install apt
expect_next dnf dnf 'sudo dnf' makecache install dnf
expect_next dnf yum 'sudo yum' makecache install
expect_next zypper '' 'sudo zypper' refresh install zypper
expect_next apk '' apk update add apk
expect_next pkg '' pkg update install pkg

# 7. Properties of the built script that can be read from its text.
cat > "$TMP/text.py" <<'PYEOF'
import re, sys
lines = open("dist/site/setup.sh", encoding="ascii").read().split("\n")
s = "\n".join(lines)
bad = 0
i = lines.index("set -eu")
cmds = [l for l in lines[i + 1:] if l.strip() and not l.lstrip().startswith("#")]
if cmds[:3] != ["PATH=/usr/sbin:/usr/bin:/sbin:/bin", "export PATH", "umask 022"]:
    print("PATH, export PATH and umask 022 do not follow set -eu directly"); bad += 1
if "/tmp" in s:
    print("setup.sh mentions /tmp"); bad += 1
# Only FreeBSD names its CPU arm64, and the line that accepts it starts with the pkg family.
for l in lines:
    if "arm64" in l and "pkg:" not in l and not l.lstrip().startswith("#"):
        print("setup.sh accepts arm64 outside the pkg family: %s" % l.strip()); bad += 1
m = re.search(r"write_rpm_repo /etc/zypp/repos.d/splicefs.repo '([^']*)'", s)
if not m or m.group(1).split("\n") != ["autorefresh=1", "gpgcheck=1", "repo_gpgcheck=1", "pkg_gpgcheck=1"]:
    print("zypper repo lines are not autorefresh, gpgcheck, repo_gpgcheck, pkg_gpgcheck"); bad += 1
sys.exit(1 if bad else 0)
PYEOF
run "7. built setup.sh: PATH and umask first, no /tmp, arm64 only for pkg, zypper lines" python3 -I "$TMP/text.py"

# The script only sets up the repository. No package manager command that installs, upgrades or
# refreshes anything may be run, and the install_ functions are gone. Text inside quotes is
# printed text, so quoted strings are removed before the search; the one command that is quoted
# in a call, the rpm tool variable, is searched before that.
cat > "$TMP/noinstall.py" <<'PYEOF'
import re, sys
lines = open("dist/site/setup.sh", encoding="ascii").read().split("\n")
mgr = r'(?:\b(?:apt-get|apt|dnf|yum|zypper|apk|pkg|dpkg)\b|\$\{?RPM_TOOL\}?"?)'
verbs = (r'install|add|upgrade|dist-upgrade|update|refresh|makecache|remove|in|'
         r'-i|--install|--upgrade')
manager_re = re.compile(mgr + r'\s+(?:-\S+\s+)*(?:' + verbs + r')\b')
rpm_re = re.compile(r'\brpm\s+(?:-(?!q)[a-zA-Z]*[iUF]|--install|--upgrade|--freshen)')
bad = 0
in_key = False
for n, line in enumerate(lines, 1):
    if line.endswith("<<'KEY_EOF'"):
        in_key = True
        continue
    if line == "KEY_EOF":
        in_key = False
        continue
    if in_key or line.lstrip().startswith("#"):
        continue
    raw = re.search(r'\$\{?RPM_TOOL\}?"?\s+\S', line) and not re.search(r'=', line)
    stripped = re.sub(r'"[^"]*"|\'[^\']*\'', '""', line)
    if raw or manager_re.search(stripped) or rpm_re.search(stripped):
        print("line %d runs a package command: %s" % (n, line.strip())); bad += 1
    if re.search(r'\binstall_\w+', line):
        print("line %d still has an install_ function: %s" % (n, line.strip())); bad += 1
sys.exit(1 if bad else 0)
PYEOF
run "7. built setup.sh: no package is installed, upgraded or refreshed" python3 -I "$TMP/noinstall.py"

# 8. Signing and publishing with throwaway keys. Nothing here touches a real key or host;
# the site is built in the temporary folder, so dist/site stays the normal build.
if ! command -v gpg >/dev/null 2>&1; then
  skip "8. gpg is not on the PATH, signing and publishing not checked"
elif ! command -v rsync >/dev/null 2>&1; then
  skip "8. rsync is not on the PATH, signing and publishing not checked"
else
  mkdir -p "$TMP/gk" "$TMP/ka" "$TMP/kb"
  chmod 700 "$TMP/gk"
  for k in a b; do
    GNUPGHOME=$TMP/gk gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
      --quick-generate-key "check-$k <check-$k@example.invalid>" rsa3072 sign never 2>/dev/null
    GNUPGHOME=$TMP/gk gpg --batch --armor --export "check-$k@example.invalid" \
      > "$TMP/k$k/splicefs.asc"
    GNUPGHOME=$TMP/gk gpg --batch --pinentry-mode loopback --passphrase '' --armor \
      --export-secret-keys "check-$k@example.invalid" > "$TMP/k$k/secret.asc" 2>/dev/null
    cp keys/splicefs.rsa.pub "$TMP/k$k/"
  done
  SIGNSITE=$TMP/sitesign
  # ls is the one listing format that is the same on macOS and Linux; stat is not.
  # shellcheck disable=SC2012
  perms() { ls -ld "$1" | cut -c1-10; }
  if SITE_DIR=$SIGNSITE KEYS_DIR=$TMP/ka sh scripts/build-site.sh > "$TMP/out" 2>&1; then
    pass "8. site builds with a throwaway public key"
  else
    fail "8. site builds with a throwaway public key"
    sed 's/^/        /' "$TMP/out"
  fi
  sign() { SITE_DIR=$SIGNSITE KEYS_DIR=$TMP/ka SIGNING_KEY_FILE=$1 sh scripts/sign-site.sh; }

  run "8. sign-site.sh signs with the matching key" sign "$TMP/ka/secret.asc"
  verify_home=$TMP/vh
  mkdir "$verify_home"
  chmod 700 "$verify_home"
  GNUPGHOME=$verify_home gpg --batch --quiet --import "$TMP/ka/splicefs.asc" 2>/dev/null
  run "8. setup.sh.asc verifies" env GNUPGHOME="$verify_home" gpg --batch --verify \
    "$SIGNSITE/setup.sh.asc" "$SIGNSITE/setup.sh"

  cp "$SIGNSITE/setup.sh" "$TMP/setup.sh.orig"
  echo "# tampered" >> "$SIGNSITE/setup.sh"
  if GNUPGHOME=$verify_home gpg --batch --verify "$SIGNSITE/setup.sh.asc" \
    "$SIGNSITE/setup.sh" > "$TMP/out" 2>&1; then
    fail "8. a tampered setup.sh fails verification"
  else
    pass "8. a tampered setup.sh fails verification"
  fi
  cp "$TMP/setup.sh.orig" "$SIGNSITE/setup.sh"

  if sign "$TMP/kb/secret.asc" > "$TMP/out" 2>&1; then
    fail "8. sign-site.sh fails for a secret key that does not match keys/"
  else
    pass "8. sign-site.sh fails for a secret key that does not match keys/"
  fi
  if env -u SIGNING_KEY_FILE SITE_DIR="$SIGNSITE" KEYS_DIR="$TMP/ka" sh scripts/sign-site.sh \
    > "$TMP/out" 2>&1; then
    fail "8. sign-site.sh fails without SIGNING_KEY_FILE"
  else
    pass "8. sign-site.sh fails without SIGNING_KEY_FILE"
  fi

  # openrsync, the rsync on macOS, has no --chmod; the GNU rsync on Linux and the runners does.
  RSYNC_OK=1
  rsync --chmod=F644 --list-only "$TMP" > /dev/null 2>&1 || RSYNC_OK=0
  # The target already holds a folder that other pipelines own; it must survive untouched.
  if [ "$RSYNC_OK" -eq 0 ]; then
    skip "8. rsync has no --chmod here (openrsync), publish.sh send not run"
  else
    mkdir -p "$TMP/remote/server"
    echo keep > "$TMP/remote/server/keep.txt"
    chmod 600 "$TMP/remote/server/keep.txt"
    pub() { SITE_DIR=$SIGNSITE UPLOAD_TARGET=$TMP/remote sh scripts/publish.sh send; }
    run "8. publish.sh send to a local folder" pub
    modes_ok=1
    for f in index.html setup.sh setup.sh.sha256 setup.sh.asc keys/splicefs.asc \
      keys/splicefs.rsa.pub; do
      perm_file=$(perms "$TMP/remote/$f")
      [ "$perm_file" = '-rw-r--r--' ] || modes_ok=0
      cmp -s "$SIGNSITE/$f" "$TMP/remote/$f" || modes_ok=0
    done
    perm_dir=$(perms "$TMP/remote/keys")
    [ "$perm_dir" = 'drwxr-xr-x' ] || modes_ok=0
    if [ "$modes_ok" -eq 1 ]; then
      pass "8. the six files arrived with modes 644 and folder 755"
    else
      fail "8. the six files arrived with modes 644 and folder 755"
    fi
    keep_text=$(cat "$TMP/remote/server/keep.txt")
    remote_names=$(cd "$TMP/remote" && echo *)
    perm_keep=$(perms "$TMP/remote/server/keep.txt")
    if [ "$keep_text" = keep ] &&
      [ "$remote_names" = 'index.html keys server setup.sh setup.sh.asc setup.sh.sha256' ] &&
      [ "$perm_keep" = '-rw-------' ]; then
      pass "8. server/keep.txt is untouched and nothing else appeared"
    else
      fail "8. server/keep.txt is untouched and nothing else appeared"
    fi

    # The upload goes in three passes and stops when one fails: the page and the keys, then
    # setup.sh, then its hash and its signature. A wrapper for rsync is put on the PATH: it
    # counts the real passes, saves a copy of the target folder after each, and makes the pass
    # named by FAIL_PASS fail, so the state between the passes can be looked at.
    mkdir "$TMP/wrap"
    cat > "$TMP/wrap/rsync" <<'WRAP'
#!/bin/sh
set -eu
# The second process that some rsync versions start for a local copy is called with --server.
for arg in "$@"; do
  case "$arg" in
    --server) exec "$REAL_RSYNC" "$@" ;;
    *) ;;
  esac
done
count=0
[ ! -f "$PASS_DIR/count" ] || count=$(cat "$PASS_DIR/count")
count=$((count + 1))
echo "$count" > "$PASS_DIR/count"
[ "$count" != "${FAIL_PASS:-0}" ] || { echo "test wrapper: pass $count fails" >&2; exit 23; }
"$REAL_RSYNC" "$@"
for dest; do :; done
cp -R "$dest" "$PASS_DIR/after-$count"
WRAP
    chmod 755 "$TMP/wrap/rsync"
    REAL_RSYNC=$(command -v rsync)
    # Sends the signed site to $1 through the wrapper. $2 is the number of the pass that
    # fails, if any. The number of passes that were run is left in PASS_TOTAL.
    send_logged() {
      rm -rf "$TMP/passes"
      mkdir "$TMP/passes"
      SEND_STATUS=0
      PATH="$TMP/wrap:$PATH" REAL_RSYNC=$REAL_RSYNC PASS_DIR=$TMP/passes FAIL_PASS=${2:-0} \
        SITE_DIR=$SIGNSITE UPLOAD_TARGET=$1 sh scripts/publish.sh send > "$TMP/out" 2>&1 ||
        SEND_STATUS=$?
      PASS_TOTAL=0
      [ ! -f "$TMP/passes/count" ] || PASS_TOTAL=$(cat "$TMP/passes/count")
    }
    files_in() { (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }
    PAGE_AND_KEYS='index.html
keys/splicefs.asc
keys/splicefs.rsa.pub'
    WITH_SCRIPT="$PAGE_AND_KEYS
setup.sh"
    ALL_SIX="$WITH_SCRIPT
setup.sh.asc
setup.sh.sha256"

    mkdir "$TMP/first"
    send_logged "$TMP/first"
    got1=$(files_in "$TMP/passes/after-1")
    got2=$(files_in "$TMP/passes/after-2")
    got3=$(files_in "$TMP/passes/after-3")
    if [ "$SEND_STATUS" -eq 0 ] && [ "$PASS_TOTAL" = 3 ] && [ "$got1" = "$PAGE_AND_KEYS" ] &&
      [ "$got2" = "$WITH_SCRIPT" ] && [ "$got3" = "$ALL_SIX" ]; then
      pass "8. a send is three passes: page and keys, then setup.sh, then its hash and signature"
    else
      fail "8. the passes of a first send (status $SEND_STATUS, $PASS_TOTAL passes)"
      sed 's/^/        /' "$TMP/out"
    fi

    # An upgrade: the old script keeps its old hash and signature until the last pass, and the
    # new script never meets anything but the old hash before that.
    mkdir -p "$TMP/upgrade/keys"
    for f in $ALL_SIX; do echo "old $f" > "$TMP/upgrade/$f"; done
    send_logged "$TMP/upgrade"
    P=$TMP/passes
    S=$SIGNSITE
    if [ "$SEND_STATUS" -eq 0 ] && [ "$PASS_TOTAL" = 3 ] &&
      cmp -s "$S/index.html" "$P/after-1/index.html" &&
      cmp -s "$S/keys/splicefs.asc" "$P/after-1/keys/splicefs.asc" &&
      grep -qx 'old setup.sh' "$P/after-1/setup.sh" &&
      grep -qx 'old setup.sh.sha256' "$P/after-1/setup.sh.sha256" &&
      cmp -s "$S/setup.sh" "$P/after-2/setup.sh" &&
      grep -qx 'old setup.sh.sha256' "$P/after-2/setup.sh.sha256" &&
      grep -qx 'old setup.sh.asc' "$P/after-2/setup.sh.asc" &&
      cmp -s "$S/setup.sh.sha256" "$P/after-3/setup.sh.sha256" &&
      cmp -s "$S/setup.sh.asc" "$P/after-3/setup.sh.asc"; then
      pass "8. an upgrade: the new script goes before its hash and signature, never after"
    else
      fail "8. the passes of an upgrade (status $SEND_STATUS, $PASS_TOTAL passes)"
      sed 's/^/        /' "$TMP/out"
    fi

    # A failed pass ends the script: no later pass runs and nothing is reported as published.
    mkdir "$TMP/fail1" "$TMP/fail2" "$TMP/fail3"
    send_logged "$TMP/fail1" 1
    left=$(files_in "$TMP/fail1")
    if [ "$SEND_STATUS" -ne 0 ] && [ "$PASS_TOTAL" = 1 ] && [ -z "$left" ] &&
      grep -q 'pass 1' "$TMP/out" && ! grep -q '^published to' "$TMP/out"; then
      pass "8. when pass 1 fails the script stops and nothing was sent"
    else
      fail "8. a failing pass 1 (status $SEND_STATUS, $PASS_TOTAL passes)"
      sed 's/^/        /' "$TMP/out"
    fi
    send_logged "$TMP/fail2" 2
    left=$(files_in "$TMP/fail2")
    if [ "$SEND_STATUS" -ne 0 ] && [ "$PASS_TOTAL" = 2 ] && [ "$left" = "$PAGE_AND_KEYS" ] &&
      grep -q 'pass 2' "$TMP/out" && ! grep -q '^published to' "$TMP/out"; then
      pass "8. when pass 2 fails the script stops, and no script, hash or signature was sent"
    else
      fail "8. a failing pass 2 (status $SEND_STATUS, $PASS_TOTAL passes)"
      sed 's/^/        /' "$TMP/out"
    fi
    send_logged "$TMP/fail3" 3
    left=$(files_in "$TMP/fail3")
    if [ "$SEND_STATUS" -ne 0 ] && [ "$PASS_TOTAL" = 3 ] && [ "$left" = "$WITH_SCRIPT" ] &&
      grep -q 'pass 3' "$TMP/out" && ! grep -q '^published to' "$TMP/out"; then
      pass "8. when pass 3 fails the script stops and reports nothing as published"
    else
      fail "8. a failing pass 3 (status $SEND_STATUS, $PASS_TOTAL passes)"
      sed 's/^/        /' "$TMP/out"
    fi
  fi

  mv "$SIGNSITE/setup.sh.asc" "$TMP/asc.saved"
  if SITE_DIR=$SIGNSITE UPLOAD_TARGET=$TMP/remote2 sh scripts/publish.sh send > "$TMP/out" 2>&1 ||
    [ -e "$TMP/remote2" ]; then
    fail "8. publish.sh send refuses when setup.sh.asc is missing"
  else
    pass "8. publish.sh send refuses when setup.sh.asc is missing"
  fi
  mv "$TMP/asc.saved" "$SIGNSITE/setup.sh.asc"

  cp "$TMP/ka/secret.asc" "$TMP/loose.key"
  chmod 644 "$TMP/loose.key"
  echo 'x' > "$TMP/known_hosts"
  if SITE_DIR=$SIGNSITE UPLOAD_KEY_FILE=$TMP/loose.key UPLOAD_KNOWN_HOSTS_FILE=$TMP/known_hosts \
    sh scripts/publish.sh send > "$TMP/out" 2>&1; then
    fail "8. publish.sh send refuses a key file with mode 644"
  elif grep -q 'mode 600' "$TMP/out"; then
    pass "8. publish.sh send refuses a key file with mode 644"
  else
    fail "8. publish.sh send refuses a key file with mode 644 (wrong reason)"
    sed 's/^/        /' "$TMP/out"
  fi
fi

if [ "$FAILS" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$FAILS check(s) failed"
  exit 1
fi
