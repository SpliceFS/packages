#!/bin/sh
# check: tests/freebsd-job.sh --remove: the checks tell a good removal from each wrong one
# Host test of the --remove step of the FreeBSD setup test (tests/freebsd-job.sh): no machine and no
# pkg. The functions of the job are read from it, and run against a stand-in for the setup script
# and for pkg, in a folder of the test. What the real setup script and pkg do is proved in the
# machine, by the job.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# $1 what is tested, $2 the text the output must hold.
holds() {
    if grep -qF -e "$2" "$work/said"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: "%s" is missing from:\n' "$1" "$2"
        sed 's/^/     /' "$work/said"
        failed=$((failed + 1))
    fi
}

# The job runs alone in the machine, where no other file of the repository is, so its functions
# live in the job and are read from there.
for name in heading note_fail run_sh expect_status expect_output expect_no_files layout repo_listed \
    check_remove_clean check_remove; do
    sed -n "/^$name() {\$/,/^}\$/p" "$root/tests/freebsd-job.sh" >> "$work/functions.sh"
    grep -q "^$name() {\$" "$work/functions.sh" || { echo "FAIL: tests/freebsd-job.sh has no function $name" >&2; exit 1; }
done

# The stand-in for the setup script. It writes and removes the two files of the job and prints what
# the real script prints; BUG names the one thing it does wrong. A copy named changed.sh is a
# changed copy, which the real script refuses.
cat > "$work/setup.sh" <<'SETUP'
#!/bin/sh
bug=" $BUG "
case "$0" in
    *changed.sh) case "$bug" in *" accepts_changed "*) ;; *) echo "this copy does not match the published one"; exit 1 ;; esac ;;
    *) ;;
esac
files="$KEYFILE $REPOFILE"
if [ "${1:-}" != --remove ]; then
    mkdir -p "$(dirname "$KEYFILE")" "$(dirname "$REPOFILE")"
    content=key
    case "$bug" in *" restores_wrong "*) [ ! -f "$BOX/removed" ] || content=other ;; *) ;; esac
    echo "$content" > "$KEYFILE"
    echo "repository" > "$REPOFILE"
    exit 0
fi
for f in $files; do
    [ -e "$f" ] || continue
    case "$bug:$f" in *" leaves_key "*:"$KEYFILE") continue ;; *) ;; esac
    rm -f "$f"
    echo "removed $f"
    : > "$BOX/removed"
done
case "$bug" in *" leaves_folder "*) ;; *) rmdir "$(dirname "$KEYFILE")" "$(dirname "$REPOFILE")" 2>/dev/null || true ;; esac
case "$bug" in *" removes_package "*) rm -f "$BOX"/installed-* ;; *) ;; esac
case "$bug" in *" noisy_second "*) echo "warning: something" ;; *) ;; esac
case "$bug" in *" silent "*) ;; *)
    echo "  pkg delete splicefs-server    # the server"
    echo "  pkg delete splicefs-client    # the client" ;;
esac
SETUP

# The stand-in for pkg: it lists the repository while its file is there, and knows two packages.
mkdir -p "$work/bin"
cat > "$work/bin/pkg" <<'PKG'
#!/bin/sh
case "$1" in
    -vv) if [ -f "$REPOFILE" ] || case " $BUG " in *" still_listed "*) true ;; *) false ;; esac; then
             echo "  splicefs-server: { url : x }"
         fi ;;
    info) [ -f "$BOX/installed-$3" ] ;;
    *) exit 2 ;;
esac
PKG
chmod 755 "$work/bin/pkg"

# Runs the job's steps with the stand-in set to do $1 wrong ("" for nothing), leaving what they said
# in $work/said.
remove_case() {
    box="$work/box"
    rm -rf "$box"
    mkdir -p "$box" "$box/pkg"
    : > "$box/installed-splicefs-server"
    : > "$box/installed-splicefs-client"
    cp "$work/setup.sh" "$box/setup.sh"
    cp "$work/setup.sh" "$box/changed.sh"
    # The functions of the job go first in the script that runs them.
    cat "$work/functions.sh" - > "$box/run.sh" <<'RUN'
setup="$BOX/setup.sh"
changed="$BOX/changed.sh"
keyfile="$BOX/pkg/keys/splicefs.rsa.pub"
repofile="$BOX/pkg/repos/splicefs.conf"
setup_dirs="$BOX/pkg/keys $BOX/pkg/repos $BOX/pkg"
work="$BOX"
failed=0
out="$BOX/out"
check_remove_clean
before="$(layout)"
run_sh "$setup"
check_remove "$before" "$changed"
exit "$failed"
RUN
    status=0
    env BUG="$1" BOX="$box" PATH="$work/bin:$PATH" \
        KEYFILE="$box/pkg/keys/splicefs.rsa.pub" REPOFILE="$box/pkg/repos/splicefs.conf" \
        sh "$box/run.sh" > "$work/said" 2>&1 || status=$?
    run_status="$status"
}

remove_case ""
if [ "$run_status" -eq 0 ]; then printf 'ok   a good removal passes\n'; else
    printf 'FAIL a good removal passes:\n'; sed 's/^/     /' "$work/said"; failed=$((failed + 1)); fi

# $1 what is wrong, $2 the stand-in's bug, $3 the text the failure says.
wrong() {
    remove_case "$2"
    if [ "$run_status" -eq 0 ]; then
        printf 'FAIL %s: the checks passed\n' "$1"
        failed=$((failed + 1))
    else
        holds "$1" "$3"
    fi
}
wrong "a changed copy is not refused for --remove" accepts_changed "a changed copy with --remove exited 0, expected 1"
wrong "--remove leaves the key" leaves_key "--remove left"
wrong "--remove leaves a folder the setup made" leaves_folder "after --remove the folders are not as they were"
wrong "--remove removes a package" removes_package "--remove removed splicefs-server"
wrong "--remove does not say how to remove the packages" silent "--remove (the command that removes splicefs-server): the output does not contain"
wrong "pkg still lists the repository" still_listed "pkg still lists the repository after --remove"
wrong "a second --remove is not quiet" noisy_second "second --remove removed or warned"
wrong "the setup after --remove does not give back the files" restores_wrong "the setup after --remove did not restore"

[ "$failed" -eq 0 ]
