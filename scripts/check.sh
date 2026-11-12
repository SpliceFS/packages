#!/bin/sh
# Checks the repository and the built site. Run through "make check", which builds first.
# Needs python3 (standard library only). Uses node, dash and bash when they exist.
set -u

cd "$(dirname "$0")/.."
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

[ -f dist/site/install.sh ] || { echo "run make site first" >&2; exit 1; }

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
        if f != "LICENSE" or root != ".":
            files.append(os.path.join(root, f))
files += ["dist/site/install.sh", "dist/site/index.html", "dist/site/install.sh.sha256"]
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
for f in install.sh.in dist/site/install.sh steps/*.sh scripts/*.sh; do
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
step = {k: open("steps/%s.sh" % k).read() for k in ("apt", "dnf", "zypper", "apk")}
base = "https://packages.splicefs.org"
curl = "curl -fsSL %s/install.sh -o splicefs-install.sh &&\n  sudo sh splicefs-install.sh server\n" % base
wget = "wget -qO splicefs-install.sh %s/install.sh &&\n  sudo sh splicefs-install.sh server\n" % base
expected = [curl, wget, "sha256sum splicefs-install.sh\n"]
for k, cmd in (("apt", "sudo apt-get install -y splicefs-%s\n"), ("dnf", "sudo dnf install -y splicefs-%s\n"),
               ("zypper", "sudo zypper --non-interactive install splicefs-%s\n"), ("apk", "apk add splicefs-%s\n")):
    expected += [step[k], cmd % "server", cmd % "client"]
bad = 0
if len(blocks) != len(expected):
    print("page has %d code blocks, expected %d" % (len(blocks), len(expected))); bad += 1
for i, (got, want) in enumerate(zip(blocks, expected)):
    if got != want:
        print("block %d differs from its source" % (i + 1)); bad += 1
sys.exit(1 if bad else 0)
PYEOF
run "3. page code blocks match steps/ and the install lines" python3 -I "$TMP/blocks.py" "$TMP/blocks.json"

# 4. The built script: keys byte-identical, no placeholder left, last line, checksum.
cat > "$TMP/built.py" <<'PYEOF'
import hashlib, re, sys
s = open("dist/site/install.sh", encoding="ascii").read()
bad = 0
for key in ("keys/splicefs.asc", "keys/splicefs.rsa.pub"):
    k = open(key, encoding="ascii").read()
    if ("<<'KEY_EOF'\n" + k + "KEY_EOF\n") not in s:
        print("%s is not embedded byte for byte" % key); bad += 1
if re.search(r"@[A-Z_]+@", s):
    print("placeholder left in install.sh"); bad += 1
if not s.endswith('\nmain "$@"\n'):
    print('last line is not main "$@"'); bad += 1
want = hashlib.sha256(open("dist/site/install.sh", "rb").read()).hexdigest() + "  install.sh\n"
if open("dist/site/install.sh.sha256").read() != want:
    print("install.sh.sha256 does not match"); bad += 1
sys.exit(1 if bad else 0)
PYEOF
run "4. built install.sh: keys, placeholders, last line, sha256" python3 -I "$TMP/built.py"

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
expect "6. no argument: usage, exit 2" 2 "usage:" sh dist/site/install.sh
expect "6. bad argument: usage, exit 2" 2 "usage:" sh dist/site/install.sh nonsense
expect "6. not root: message, exit 1" 1 "run this script as root, for example with sudo" \
  sh dist/site/install.sh server

if [ "$FAILS" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$FAILS check(s) failed"
  exit 1
fi
