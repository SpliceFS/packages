#!/bin/sh
# check: tests/prepare.sh: the program repositories only build their programs, the packages are made here
# Test of tests/prepare.sh (make e2e-prepare): the server and the client repositories have no
# packaging targets, so the programs come from their own build (make build-all) and the packages
# from the targets of this repository, the way CI makes them. Runs on the host, no Docker (part
# of make check): the repositories are fixtures whose Makefiles only leave a trace.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
failed=0

# The packaging repository: this script, and a Makefile whose targets write what the real ones
# are given into a log, and fail when the programs are not where BIN says.
mkdir -p "$tree/packages/tests"
cp "$root/tests/prepare.sh" "$tree/packages/tests/"
cat > "$tree/packages/Makefile" <<'EOF'
packages:
	test -f "$(BIN)/linux-amd64/prog"
	mkdir -p dist/keys dist/$(PROGRAM)
	touch dist/keys/splicefs.asc dist/keys/splicefs.rsa.pub
	echo "packages $(PROGRAM) $(BIN) $(SRC) $(VERSION)" >> "$(CURDIR)/calls"

repo:
	mkdir -p dist/$(PROGRAM)/repo
	echo "$(PROGRAM)" > dist/$(PROGRAM)/repo/index
	echo "repo $(PROGRAM)" >> "$(CURDIR)/calls"
EOF

# A program repository has its own build and nothing else: any other target is an error.
for program in server client; do
    mkdir -p "$tree/$program"
    echo "1.2.3" > "$tree/$program/VERSION"
    cat > "$tree/$program/Makefile" <<'EOF'
build-all:
	mkdir -p dist/bin/linux-amd64
	touch dist/bin/linux-amd64/prog
	echo "build-all" >> "$(CURDIR)/calls"
EOF
done

# Output of an earlier run, which must not reach the new one.
mkdir -p "$tree/packages/dist/server" "$tree/packages/dist/e2e/old"
touch "$tree/packages/dist/server/stale.deb"

(cd "$tree/packages" && sh tests/prepare.sh >"$tree/out" 2>&1) || {
    cat "$tree/out"
    echo "FAIL tests/prepare.sh failed"
    exit 1
}

# $1 case name, $2 what is wanted, $3 what is found.
same() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: wanted "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

# The names in the folder $1, in the order of the shell's glob.
names() {
    for entry in "$1"/*; do printf '%s ' "${entry##*/}"; done
}

for program in server client; do
    calls="$(cat "$tree/$program/calls")"
    same "$program is built by its own repository, once" "build-all" "$calls"
done
calls="$(cat "$tree/packages/calls")"
same "the packages are made here from the programs, the source and the version of each" \
    "packages server $tree/server/dist/bin $tree/server v1.2.3
repo server
packages client $tree/client/dist/bin $tree/client v1.2.3
repo client" "$calls"
parts="$(names "$tree/packages/dist/e2e")"
same "the repositories and the keys are where the install tests read them" "client keys server " "$parts"
repository="$(cat "$tree/packages/dist/e2e/server/index")"
same "the repository of each program is the one made here" "server" "$repository"
keys="$(names "$tree/packages/dist/e2e/keys")"
same "the public keys are copied for the site" "splicefs.asc splicefs.rsa.pub " "$keys"
stale=gone
if [ -e "$tree/packages/dist/server/stale.deb" ]; then stale=left; fi
same "nothing of an earlier run is left" "gone" "$stale"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "e2e-prepare checks done"
