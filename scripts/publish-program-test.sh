#!/bin/sh
# check: publish-program.sh: the repositories of a program uploaded in order, nothing published lost
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
# The FreeBSD releases come from the list the packages are built for. Each major version has
# one folder for each CPU type, with a package and the catalog files pkg repo writes.
freebsd_dirs=""
majors=$(awk '!/^#/ && NF { split($1, v, "."); print v[1] }' packaging/freebsd/releases | sort -un)
for major in $majors; do
    for arch in amd64 aarch64; do
        d="freebsd/FreeBSD:$major:$arch"
        freebsd_dirs="$freebsd_dirs $d"
        mkdir -p "$base/$d/All"
        echo "$d package" > "$base/$d/All/splicefs-server-1.pkg"
        for f in meta meta.conf packagesite.pkg data.pkg meta.conf.sig; do
            echo "$d $f" > "$base/$d/$f"
        done
    done
done
fb_first="${freebsd_dirs# }"
fb_first="${fb_first%% *}"

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

    # (k) A published FreeBSD package that is missing locally is refused like any other.
    oldfb="$fb_first/All/old-package-0.0.1.pkg"
    echo old > "$tmp/target/$oldfb"
    send "$base" "$tmp/target"
    if [ "$send_status" -eq 0 ]; then
        fail "k send went ahead although a published FreeBSD package is missing locally"
    elif [ -f "$tmp/target/$oldfb" ] && grep -q "$oldfb" "$tmp/out"; then
        pass "k send refused because a published FreeBSD package is missing locally"
    else
        fail "k refusal for a FreeBSD package missing locally"; sed 's/^/     /' "$tmp/out"
    fi
    rm "$tmp/target/$oldfb"
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

# (j) A FreeBSD catalog that is missing stops the send before anything is sent, so a release
# whose FreeBSD job did not leave its repository never goes out with the old catalog.
cp -R "$base" "$tmp/nofb"
rm "$tmp/nofb/$fb_first/meta.conf"
send "$tmp/nofb" "$tmp/neverthere3"
if [ "$send_status" -eq 0 ] || [ -e "$tmp/neverthere3" ]; then
    fail "j send must refuse a repository without a FreeBSD meta.conf"
elif grep -q "missing .*$fb_first/meta.conf" "$tmp/out" && grep -q 'make package-freebsd' "$tmp/out"; then
    pass "j send refuses a repository without $fb_first/meta.conf, and sends nothing"
else
    fail "j send refused for the wrong reason"; sed 's/^/     /' "$tmp/out"
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

    index_re='^(apt/dists/|rpm/[^/]+/repodata/|alpine/[^/]+/(APKINDEX\.tar\.gz|[^/]+\.(sig|asc))$'
    index_re="$index_re"'|freebsd/[^/]+/(meta|meta\.conf|packagesite\.pkg|data\.pkg|[^/]+\.(sig|asc))$)'
    files_in "$base" > "$tmp/all_files"
    grep -E "$index_re" "$tmp/all_files" > "$tmp/index_files" || true
    grep -Ev "$index_re" "$tmp/all_files" > "$tmp/other_files" || true
    if grep -qx 'apt/dists/stable/InRelease' "$tmp/index_files" &&
        grep -q '^rpm/x86_64/repodata/repomd.xml.asc$' "$tmp/index_files" &&
        grep -q '^alpine/x86_64/APKINDEX.tar.gz$' "$tmp/index_files" &&
        grep -q '/packagesite.pkg$' "$tmp/index_files" &&
        ! grep -q '\.deb$\|\.rpm$\|\.apk$\|/All/' "$tmp/index_files" &&
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
    # Each old index gets the time stamp of the new one: a file can change in the second it was
    # published in, and some old indexes are as long as the new ones (each stand-in holds its own
    # path, and freebsd/FreeBSD:14:aarch64/meta is as long as the old text). The send must still
    # see the change; without this the case passed or failed with the speed of the machine.
    while read -r f; do
        echo "$old_text" > "$tmp/upgrade/$f"
        touch -r "$base/$f" "$tmp/upgrade/$f"
    done < "$tmp/index_files"
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

# (j) A published package is never replaced by a file with other content under the same name: a
# changed package gets a new name (a new revision), so the one that is published stays what
# clients and their signatures were made from. The same file again, and a new name, are sent. This
# runs also where rsync has no --chmod (openrsync): a wrapper that drops that option is put on
# the PATH, which changes nothing the check looks at.
if [ "$chmod_ok" -eq 0 ]; then
    mkdir "$tmp/nochmod"
    cat > "$tmp/nochmod/rsync" <<'WRAP'
#!/bin/sh
set -eu
for arg; do
    shift
    case "$arg" in
        --chmod=*) ;;
        *) set -- "$@" "$arg" ;;
    esac
done
exec "$REAL_RSYNC" "$@"
WRAP
    chmod 755 "$tmp/nochmod/rsync"
fi
real_rsync_j="$(command -v rsync)"
send_j() {
    send_status=0
    PATH="$tmp/nochmod:$PATH" REAL_RSYNC="$real_rsync_j" \
        PROGRAM="$program" REPO_DIR="$1" UPLOAD_TARGET="$2" sh scripts/publish-program.sh send \
        >"$tmp/out" 2>&1 || send_status=$?
}
pkg="rpm/x86_64/splicefs-server-1.rpm"
newpkg="rpm/x86_64/splicefs-server-1-1.rpm"
mkdir "$tmp/j_target"
cp -R "$base/." "$tmp/j_target"
cp -R "$base" "$tmp/j_changed"
echo "other content" > "$tmp/j_changed/$pkg"
cp "$base/$pkg" "$tmp/j_changed/$newpkg"
send_j "$tmp/j_changed" "$tmp/j_target"
if [ "$send_status" -eq 0 ]; then
    fail "j send must refuse a package that is published with other content"
elif grep -q "$pkg" "$tmp/out" && grep -qx "$pkg" "$tmp/j_target/$pkg" && [ ! -e "$tmp/j_target/$newpkg" ]; then
    pass "j send refused to replace $pkg, and sent nothing of that run"
else
    fail "j refusal to replace a package"; sed 's/^/     /' "$tmp/out"
fi

# The same content with another time stamp is not a change, and the index files may change.
cp -R "$base" "$tmp/j_same"
touch -t 202001010000 "$tmp/j_same/$pkg"
echo "a new index" > "$tmp/j_same/apt/dists/stable/Release"
send_j "$tmp/j_same" "$tmp/j_target"
if [ "$send_status" -eq 0 ] && grep -qx "a new index" "$tmp/j_target/apt/dists/stable/Release"; then
    pass "j the same package again and a new index are sent"
else
    fail "j the same package again"; sed 's/^/     /' "$tmp/out"
fi

# A new name is sent, and the package that was published stays.
cp -R "$base" "$tmp/j_new"
cp "$base/$pkg" "$tmp/j_new/$newpkg"
send_j "$tmp/j_new" "$tmp/j_target"
if [ "$send_status" -eq 0 ] && [ -f "$tmp/j_target/$newpkg" ] && grep -qx "$pkg" "$tmp/j_target/$pkg"; then
    pass "j a package under a new name is sent next to the published one"
else
    fail "j a package under a new name"; sed 's/^/     /' "$tmp/out"
fi

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "publish-program checks done"
