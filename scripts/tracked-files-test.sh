#!/bin/sh
# Test of scripts/tracked-files.sh (part of make check): a tracked compiled program, a file over
# 1 MiB and a file that names a private place are each refused and named, and a tree without
# them passes. Each case is a small repository of its own, so the test does not depend on what
# this repository tracks.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# The names are put together here so that this file does not hold the names it checks for.
place="pho""enix"
other="CASTLE-""ROCK"

# $1 case name, $2 the exit status wanted, $3 text the output must hold, or empty. The files are
# made by the caller in "$work/repo", which is a new repository for every case.
run() {
    status=0
    (cd "$work/repo" && git add -A && sh "$root/scripts/tracked-files.sh") > "$work/out" 2>&1 || status=$?
    if [ "$status" -ne "$2" ] || { [ -n "$3" ] && ! grep -F -q -e "$3" "$work/out"; }; then
        printf 'FAIL %s: status %s, wanted %s\n' "$1" "$status" "$2"
        sed 's/^/     /' "$work/out"
        failed=$((failed + 1))
    else
        echo "ok   $1"
    fi
}

fresh() {
    rm -rf "$work/repo"
    mkdir "$work/repo"
    git init -q "$work/repo"
}

# $1 file name, $2 bytes of zeros to write
zeros() {
    head -c "$2" /dev/zero > "$work/repo/$1"
}

fresh
echo "plain text" > "$work/repo/a.txt"
run "a plain tree passes" 0 "tracked files: no compiled program"

fresh
zeros exact 1048576
run "a file of exactly 1 MiB passes" 0 ""

fresh
zeros big 1048577
run "a file over 1 MiB is refused with its size" 1 "tracked file larger than 1 MiB: big (1048577 bytes)"

for magic in '\177ELF' '\317\372\355\376' '\316\372\355\376' '\312\376\272\276' 'MZ'; do
    fresh
    # shellcheck disable=SC2059 # the formats are the fixed list above
    printf "$magic"'rest of the file\n' > "$work/repo/prog"
    run "a program starting with the bytes $magic is refused" 1 "tracked file is a compiled program: prog"
done

fresh
printf 'text with %s inside\n' "$place" > "$work/repo/notes"
run "a private name is refused" 1 "tracked file holds a private name: notes"

fresh
printf 'text with %s inside\n' "$other" > "$work/repo/notes"
run "a private name in another case is refused" 1 "tracked file holds a private name: notes"

fresh
mkdir "$work/repo/a folder"
printf 'text with %s inside\n' "$place" > "$work/repo/a folder/a name.txt"
run "a file with spaces in its path is read" 1 "tracked file holds a private name: a folder/a name.txt"

fresh
printf '\000\001binary then %s\n' "$place" > "$work/repo/data"
run "a private name behind a zero byte is found" 1 "tracked file holds a private name: data"

fresh
printf 'Copyright %s\n' "$place" > "$work/repo/LICENSE"
run "the LICENSE file may name the company" 0 ""

fresh
mkdir "$work/repo/sub"
printf 'Copyright %s\n' "$place" > "$work/repo/sub/LICENSE"
run "only the LICENSE file of the top folder is excepted" 1 "tracked file holds a private name: sub/LICENSE"

fresh
printf 'x\n' > "$work/repo/-n"
printf 'x\n' > "$work/repo/a=b"
run "a name that looks like an option or an assignment is a file" 0 ""

fresh
printf 'x\n' > "$work/repo/gone"
(cd "$work/repo" && git add -A && rm gone)
status=0
(cd "$work/repo" && sh "$root/scripts/tracked-files.sh") > "$work/out" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then echo "ok   a tracked file that is deleted is skipped"; else
    echo "FAIL a tracked file that is deleted is skipped: status $status"
    failed=$((failed + 1))
fi

fresh
printf 'text with %s inside\n' "$place" > "$work/repo/notes"
(cd "$work/repo" && git add -A && git rm -q --cached notes)
status=0
(cd "$work/repo" && sh "$root/scripts/tracked-files.sh") > "$work/out" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then echo "ok   an untracked file is not read"; else
    echo "FAIL an untracked file is not read: status $status"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
