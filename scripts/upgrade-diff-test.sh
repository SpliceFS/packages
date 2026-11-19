#!/bin/sh
# check: upgrade-diff.sh: when the packaging of two versions differs
# Tests scripts/upgrade-diff.sh, the part of the upgrade test that decides whether the
# packaging changed, with small hand-made package listings. Runs on the host, no Docker
# (make upgrade-diff-test, part of make check). The listing format is described in
# scripts/upgrade-lib.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
failed=0

# The old package. The programs (a program may have several) and the documents are what the
# program's own source gives the package, which the program's version changes.
cat > "$work/old" <<'LISTING'
dir 755 root:root - /etc/splicefs
dir 755 root:root - /etc/splicefs/demo
dir 755 root:root - /etc/splicefs/demo/conf.d
file 755 root:root program-sum-1 /usr/bin/demod
file 755 root:root control-sum-1 /usr/bin/democtl
file 644 root:root unit-sum-1 /usr/lib/systemd/system/demod.service
file 644 root:root changelog-sum-1 /usr/share/doc/splicefs-demo/CHANGELOG.md
file 644 root:root readme-sum-1 /usr/share/doc/splicefs-demo/README.md
meta control Depends: passwd
script postinst postinst-sum-1
script prerm prerm-sum-1
LISTING

# $1 name of the case, $2 file name of the new listing, $3 expected status, $4 text that must
# be in the printed differences (empty: nothing may be printed). The programs and the documents
# are named the way scripts/upgrade-test.sh names them: every program of the package, then every
# document, by name.
check() {
    status=0
    out="$(sh scripts/upgrade-diff.sh "$work/old" "$work/$2" demod democtl -- README.md CHANGELOG.md)" || status=$?
    if [ "$status" -ne "$3" ]; then
        printf 'FAIL %s: status %s, want %s\n' "$1" "$status" "$3"
        failed=$((failed + 1))
    elif [ -z "$4" ] && [ -n "$out" ]; then
        printf 'FAIL %s: printed differences where there are none: %s\n' "$1" "$out"
        failed=$((failed + 1))
    elif [ -n "$4" ] && ! printf '%s\n' "$out" | grep -qF -e "$4"; then
        printf 'FAIL %s: the differences do not name "%s": %s\n' "$1" "$4" "$out"
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

# $1 file name of the new listing. Reads the new listing from standard input.
new() { cat > "$work/$1"; }

# Nothing to do: only the program and the documents changed, or only the order of the lines.
sed -e 's/program-sum-1/program-sum-2/' -e 's/control-sum-1/control-sum-2/' -e 's/changelog-sum-1/changelog-sum-2/' "$work/old" > "$work/program"
check "only the programs and the changelog differ" program 0 ""
# A document comes from the source of the program, not from the packaging, and no upgrade can
# fail on what is written in it.
sed 's/readme-sum-1/readme-sum-2/' "$work/old" > "$work/content"
check "only the content of a document differs" content 0 ""
sort -r "$work/old" > "$work/shuffled"
check "the same lines in another order" shuffled 0 ""

# An upgrade test is needed.
sed 's/postinst-sum-1/postinst-sum-2/' "$work/old" > "$work/script"
check "an install script differs" script 1 "script postinst"
sed 's/^file 644 root:root unit-sum-1/file 755 root:root unit-sum-1/' "$work/old" > "$work/mode"
check "a mode differs" mode 1 "+ file 755 root:root unit-sum-1"
sed 's/^file 644 root:root unit-sum-1/file 644 splicefs:splicefs unit-sum-1/' "$work/old" > "$work/owner"
check "an owner differs" owner 1 "+ file 644 splicefs:splicefs"
sed 's/^file 644 root:root readme-sum-1/file 600 root:root readme-sum-1/' "$work/old" > "$work/docmode"
check "the mode of a document differs" docmode 1 "README.md"
sed 's/Depends: passwd/Depends: passwd, adduser/' "$work/old" > "$work/depends"
check "a declared dependency differs" depends 1 "adduser"
{ cat "$work/old"; echo "file 644 root:root shares-sum-1 /etc/splicefs/demo/shares.d/default.yaml"; } > "$work/added"
check "a file was added" added 1 "+ file 644 root:root shares-sum-1 /etc/splicefs/demo/shares.d/default.yaml"
grep -v 'readme-sum-1' "$work/old" > "$work/removed"
check "a document was removed" removed 1 "- file 644 root:root - /usr/share/doc/splicefs-demo/README.md"
# The program is left out by name: a new file with another name is not the program.
{ cat "$work/old"; echo "file 755 root:root other-sum-1 /usr/bin/demod-helper"; } > "$work/helper"
check "a new program file counts" helper 1 "demod-helper"

# Wrong use is not the same as a difference.
status=0
sh scripts/upgrade-diff.sh "$work/old" "$work/missing" > /dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
    echo "ok   a missing listing is refused"
else
    printf 'FAIL a missing listing is refused: status %s, want 2\n' "$status"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "upgrade diff: all cases as expected"
