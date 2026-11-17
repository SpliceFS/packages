#!/bin/sh
# Proves publish-program.sh without a server: the upload goes to local folders through
# UPLOAD_TARGET, and the checks of the real upload path run with a throwaway ssh key. The
# repository is a small stand-in that has the files a real one has, so the test needs no Docker
# and no built packages (part of make check). A step that needs rsync --chmod prints SKIP when
# rsync has none (openrsync on macOS). Nothing here touches a real key or host.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
command -v rsync >/dev/null 2>&1 || { echo "rsync is not on the PATH" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
failed=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failed=$((failed + 1)); }
skip() { echo "SKIP $*"; }

# One program of this repository, and a repository with every file the script requires, one
# package of each format and the index files of each.
program=server
base="$tmp/base"
for f in apt/dists/stable/InRelease apt/dists/stable/Release apt/pool/main/s/splicefs-server/splicefs-server_1_amd64.deb \
    rpm/x86_64/repodata/repomd.xml rpm/x86_64/repodata/repomd.xml.asc rpm/x86_64/splicefs-server-1.rpm \
    rpm/aarch64/repodata/repomd.xml.asc rpm/aarch64/splicefs-server-1.rpm \
    alpine/x86_64/APKINDEX.tar.gz alpine/x86_64/splicefs-server-1.apk \
    alpine/aarch64/APKINDEX.tar.gz alpine/aarch64/splicefs-server-1.apk; do
    mkdir -p "$base/$(dirname "$f")"
    echo "$f" > "$base/$f"
done

chmod_ok=1
rsync --chmod=F644 --list-only "$tmp" >/dev/null 2>&1 || chmod_ok=0
# A refused send is a result to check, not a reason to stop. send always returns 0 and leaves
# the exit status of the script in send_status, so no call of it sits in a condition, where
# set -e would be off inside it.
send_status=0
publish() {
    send_status=0
    PROGRAM="$program" REPO_DIR="$1" UPLOAD_TARGET="$2" sh scripts/publish-program.sh "$3" \
        >"$tmp/out" 2>&1 || send_status=$?
}
send() { publish "$1" "$2" send; }

# (a) A send to an empty folder reproduces the repository, with the modes the web server needs.
mkdir "$tmp/target"
if [ "$chmod_ok" -eq 0 ]; then
    skip "a send to an empty folder, b stale index, c published package would disappear, i passes: rsync has no --chmod"
    cp -R "$base" "$tmp/target"
else
    send "$base" "$tmp/target"
    wrong_file_modes="$(find "$tmp/target" -type f ! -perm 644)"
    wrong_dir_modes="$(find "$tmp/target" -type d ! -perm 755)"
    if [ "$send_status" -eq 0 ] && diff -r "$base" "$tmp/target" &&
        [ -z "$wrong_file_modes" ] && [ -z "$wrong_dir_modes" ]; then
        pass "a a send to an empty folder gives the same tree, modes 644 and 755"
    else
        fail "a a send to an empty folder"; sed 's/^/     /' "$tmp/out"
    fi

    # (b) Index files that a new build replaces go; that is the only thing a send removes.
    echo stale > "$tmp/target/rpm/x86_64/repodata/stale-primary.xml.gz"
    send "$base" "$tmp/target"
    if [ "$send_status" -eq 0 ] &&
        [ ! -e "$tmp/target/rpm/x86_64/repodata/stale-primary.xml.gz" ] &&
        diff -r "$base" "$tmp/target"; then
        pass "b the stale repodata file is gone and nothing else changed"
    else
        fail "b stale repodata removed"; sed 's/^/     /' "$tmp/out"
    fi

    # A package that is published but missing here means the fetch step was skipped or
    # failed. Sending then would publish an index without it, so the send must refuse.
    old="apt/pool/main/old/old-package_0.0.1_amd64.deb"
    mkdir -p "$tmp/target/$(dirname "$old")"
    echo old > "$tmp/target/$old"
    send "$base" "$tmp/target"
    if [ "$send_status" -eq 0 ]; then
        fail "b send went ahead although a published package is missing locally"
    elif [ -f "$tmp/target/$old" ] && grep -q "$old" "$tmp/out"; then
        pass "b send refused because a published package is missing locally, and it is still there"
    else
        fail "b refusal for a package missing locally"; sed 's/^/     /' "$tmp/out"
    fi
    rm "$tmp/target/$old"
    rmdir "$tmp/target/$(dirname "$old")"

    # (c) A repository that lacks a published package is refused and nothing is deleted.
    cp -R "$base" "$tmp/copy"
    rpm="rpm/x86_64/splicefs-server-1.rpm"
    rm "$tmp/copy/$rpm"
    send "$tmp/copy" "$tmp/target"
    if [ "$send_status" -eq 0 ]; then
        fail "c send must refuse when a published package would disappear"
    elif grep -q 'would delete' "$tmp/out" && [ -f "$tmp/target/$rpm" ]; then
        pass "c send refused because $rpm would disappear, and it is still published"
    else
        fail "c send refused for the wrong reason or deleted the file"; sed 's/^/     /' "$tmp/out"
    fi
fi

# (d) fetch into an empty folder reproduces what is published. Without --chmod the published
# folder is a plain copy, which is all fetch needs.
mkdir "$tmp/fetched"
publish "$tmp/fetched" "$tmp/target" fetch
if [ "$send_status" -eq 0 ] && diff -r "$tmp/target" "$tmp/fetched"; then
    pass "d fetch reproduces the published folder"
else
    fail "d fetch"; sed 's/^/     /' "$tmp/out"
fi
mkdir "$tmp/emptyremote"
publish "$tmp/fetched2" "$tmp/emptyremote" fetch
if [ "$send_status" -eq 0 ] && [ -d "$tmp/fetched2" ]; then
    pass "d fetch from an empty remote works"
else
    fail "d fetch from an empty remote"; sed 's/^/     /' "$tmp/out"
fi

# (f) An incomplete repository is refused before anything is sent.
cp -R "$base" "$tmp/partial"
rm "$tmp/partial/alpine/aarch64/APKINDEX.tar.gz"
send "$tmp/partial" "$tmp/neverthere"
if [ "$send_status" -eq 0 ] || [ -e "$tmp/neverthere" ]; then
    fail "f send must refuse an incomplete repository"
elif grep -q 'missing .*APKINDEX.tar.gz' "$tmp/out"; then
    pass "f send refuses a repository without alpine/aarch64/APKINDEX.tar.gz"
else
    fail "f send refused for the wrong reason"; sed 's/^/     /' "$tmp/out"
fi

# (g) A program this repository does not package is refused before anything is read or sent.
send_status=0
PROGRAM=nothing REPO_DIR="$base" UPLOAD_TARGET="$tmp/neverthere2" sh scripts/publish-program.sh send \
    >"$tmp/out" 2>&1 || send_status=$?
if [ "$send_status" -ne 0 ] && [ ! -e "$tmp/neverthere2" ] && grep -q 'is not a program of this repository' "$tmp/out"; then
    pass "g an unknown program is refused, and nothing is sent"
else
    fail "g an unknown program"; sed 's/^/     /' "$tmp/out"
fi

# (h) The real upload path (no UPLOAD_TARGET) refuses a key that is not mode 600 and a missing
# known hosts file, before any connection is made. The key is a throwaway.
ssh-keygen -q -t ed25519 -N '' -f "$tmp/key" -C throwaway
: > "$tmp/known_hosts"
chmod 644 "$tmp/key"
send_status=0
PROGRAM="$program" REPO_DIR="$base" UPLOAD_KEY_FILE="$tmp/key" UPLOAD_KNOWN_HOSTS_FILE="$tmp/known_hosts" \
    sh scripts/publish-program.sh check >"$tmp/out" 2>&1 || send_status=$?
if [ "$send_status" -ne 0 ] && grep -q 'must have mode 600' "$tmp/out"; then
    pass "h a key file with mode 644 is refused"
else
    fail "h a key file with mode 644"; sed 's/^/     /' "$tmp/out"
fi
chmod 600 "$tmp/key"
send_status=0
PROGRAM="$program" REPO_DIR="$base" UPLOAD_KEY_FILE="$tmp/key" UPLOAD_KNOWN_HOSTS_FILE="$tmp/nothere" \
    sh scripts/publish-program.sh check >"$tmp/out" 2>&1 || send_status=$?
if [ "$send_status" -ne 0 ] && grep -q 'UPLOAD_KNOWN_HOSTS_FILE is not a file' "$tmp/out"; then
    pass "h a missing known hosts file is refused"
else
    fail "h a missing known hosts file"; sed 's/^/     /' "$tmp/out"
fi

# (i) The upload goes in two passes and stops when one fails. A wrapper for rsync is put on the
# PATH: it counts the real passes (a dry run is not one), saves a copy of the target folder
# after each, and makes the pass named by FAIL_PASS fail, so the state between the passes can
# be looked at. The index files are named here again, as a person reading the layout would:
# the apt dists folder, the rpm repodata folders, APKINDEX.tar.gz and the files next to them.
if [ "$chmod_ok" -eq 1 ]; then
    real_rsync="$(command -v rsync)"
    mkdir "$tmp/wrap"
    cat > "$tmp/wrap/rsync" <<'WRAP'
#!/bin/sh
set -eu
# A dry run is not a pass, and neither is the second process that some rsync versions start
# for a local copy (it is called with --server).
for arg in "$@"; do
    case "$arg" in
        --dry-run | --server) exec "$REAL_RSYNC" "$@" ;;
        *) ;;
    esac
done
count=0
[ ! -f "$PASS_DIR/count" ] || count="$(cat "$PASS_DIR/count")"
count=$((count + 1))
echo "$count" > "$PASS_DIR/count"
[ "$count" != "${FAIL_PASS:-0}" ] || { echo "test wrapper: pass $count fails" >&2; exit 23; }
"$REAL_RSYNC" "$@"
for dest; do :; done
cp -R "$dest" "$PASS_DIR/after-$count"
WRAP
    chmod 755 "$tmp/wrap/rsync"
    # Sends $1 to $2 through the wrapper. $3 is the number of the pass that fails, if any. The
    # number of passes that were run is left in pass_total.
    send_logged() {
        rm -rf "$tmp/passes"
        mkdir "$tmp/passes"
        send_status=0
        PATH="$tmp/wrap:$PATH" REAL_RSYNC="$real_rsync" PASS_DIR="$tmp/passes" \
            FAIL_PASS="${3:-0}" PROGRAM="$program" REPO_DIR="$1" UPLOAD_TARGET="$2" \
            sh scripts/publish-program.sh send >"$tmp/out" 2>&1 || send_status=$?
        pass_total=0
        [ ! -f "$tmp/passes/count" ] || pass_total="$(cat "$tmp/passes/count")"
    }
    files_in() { (cd "$1" && find . -type f | sed 's|^\./||' | sort); }

    index_re='^(apt/dists/|rpm/[^/]+/repodata/|alpine/[^/]+/(APKINDEX\.tar\.gz|[^/]+\.(sig|asc))$)'
    files_in "$base" > "$tmp/all_files"
    grep -E "$index_re" "$tmp/all_files" > "$tmp/index_files" || true
    grep -Ev "$index_re" "$tmp/all_files" > "$tmp/other_files" || true
    if grep -qx 'apt/dists/stable/InRelease' "$tmp/index_files" &&
        grep -q '^rpm/x86_64/repodata/repomd.xml.asc$' "$tmp/index_files" &&
        grep -q '^alpine/x86_64/APKINDEX.tar.gz$' "$tmp/index_files" &&
        ! grep -q '\.deb$\|\.rpm$\|\.apk$' "$tmp/index_files" &&
        grep -q '\.deb$' "$tmp/other_files"; then
        pass "i the index files are told apart from the packages"
    else
        fail "i the list of index files is wrong"
    fi

    # The first publication: pass 1 leaves a folder without any index file, pass 2 completes it.
    mkdir "$tmp/first"
    send_logged "$base" "$tmp/first"
    after_first="$(files_in "$tmp/passes/after-1")"
    want_first="$(cat "$tmp/other_files")"
    if [ "$send_status" -eq 0 ] && [ "$pass_total" = 2 ] && [ "$after_first" = "$want_first" ] &&
        diff -r "$base" "$tmp/first" >/dev/null; then
        pass "i a send is two passes: all packages first, then the index files"
    else
        fail "i the passes of a first send (status $send_status, $pass_total passes)"
        sed 's/^/     /' "$tmp/out"
    fi

    # An upgrade: the index of the old release stays until pass 2, and so do the deletions.
    cp -R "$base" "$tmp/upgrade"
    new_pkg="rpm/x86_64/splicefs-server-1.rpm"
    rm "$tmp/upgrade/$new_pkg"
    old_text="the index of the release before"
    while read -r f; do echo "$old_text" > "$tmp/upgrade/$f"; done < "$tmp/index_files"
    stale=rpm/x86_64/repodata/stale-primary.xml.gz
    echo stale > "$tmp/upgrade/$stale"
    send_logged "$base" "$tmp/upgrade"
    old_kept=1
    while read -r f; do
        grep -qx "$old_text" "$tmp/passes/after-1/$f" || old_kept=0
    done < "$tmp/index_files"
    if [ "$send_status" -eq 0 ] && [ "$pass_total" = 2 ] && [ "$old_kept" -eq 1 ] &&
        [ -f "$tmp/passes/after-1/$new_pkg" ] && [ -f "$tmp/passes/after-1/$stale" ] &&
        [ ! -e "$tmp/upgrade/$stale" ] && diff -r "$base" "$tmp/upgrade" >/dev/null; then
        pass "i an upgrade: the new package is there before any new index, the deletion comes last"
    else
        fail "i the passes of an upgrade (status $send_status)"
        sed 's/^/     /' "$tmp/out"
    fi

    # A failed pass ends the script: no later pass runs and nothing is reported as published.
    mkdir "$tmp/fail1" "$tmp/fail2"
    send_logged "$base" "$tmp/fail1" 1
    left="$(files_in "$tmp/fail1")"
    if [ "$send_status" -ne 0 ] && [ "$pass_total" = 1 ] && [ -z "$left" ] &&
        grep -q 'pass 1' "$tmp/out" && ! grep -q '^published to' "$tmp/out"; then
        pass "i when pass 1 fails the script stops and nothing was sent"
    else
        fail "i a failing pass 1 (status $send_status)"; sed 's/^/     /' "$tmp/out"
    fi
    send_logged "$base" "$tmp/fail2" 2
    left="$(files_in "$tmp/fail2")"
    if [ "$send_status" -ne 0 ] && [ "$pass_total" = 2 ] && [ "$left" = "$want_first" ] &&
        grep -q 'pass 2' "$tmp/out" && ! grep -q '^published to' "$tmp/out"; then
        pass "i when pass 2 fails the script stops, and no index file was sent"
    else
        fail "i a failing pass 2 (status $send_status)"; sed 's/^/     /' "$tmp/out"
    fi
fi

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "publish-program checks done"
