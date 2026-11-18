#!/bin/sh
# Test that the tests which start from a published release (scripts/lifecycle-repo.sh and
# scripts/upgrade-test.sh) start from the release the build recorded (UPGRADE_FROM of
# dist/PROGRAM/version), and ask for the newest release only when the build recorded none. A
# release made between the build and the test must change nothing: the newest release would be
# newer than the packages, and the upgrade a downgrade. Runs on the host, no Docker and no network
# (part of make check): curl and docker are stand-ins in a folder at the front of PATH. The newest
# release is the tag in the file "latest" of the stand-ins, which the test changes after the build
# to make a release happen.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

stand="$work/stand-in"
mkdir -p "$stand/bin"
# curl: the newest release is the one in "latest"; a download writes its own URL into the file.
# Every call is logged. docker: a pull works and nothing runs, so a test ends at its first
# container, after it has downloaded what it starts from.
cat > "$stand/bin/curl" <<'STUB'
#!/bin/sh
echo "$*" >> "$STAND_IN/calls"
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        https://*) url="$1" ;;
        *) ;;
    esac
    shift
done
case "$url" in
    */releases/latest) printf 'https://github.com/x/releases/tag/%s' "$(cat "$STAND_IN/latest")" ;;
    *) printf '%s\n' "$url" > "$out" ;;
esac
STUB
cat > "$stand/bin/docker" <<'STUB'
#!/bin/sh
[ "$1" = pull ]
STUB
chmod 755 "$stand/bin/curl" "$stand/bin/docker"

# The part of the repository the two scripts read, in a tree of its own: they write into dist.
tree="$work/tree"
mkdir -p "$tree"
cp -R "$root/scripts" "$root/programs" "$root/packaging" "$tree/"

# Makes the packages of the client in the tree, as make packages leaves them, recorded as
# v0.5.35 revision 1 with the release $1 to upgrade from (empty: none).
build() {
    rm -rf "$tree/dist"
    # The inner shell expands $1 and $2, which are the tree and the release.
    # shellcheck disable=SC2016
    files="$(cd "$tree" && PROGRAM=client VERSION=v0.5.35 REVISION=1 PACKAGE_DATE=20261112 \
        sh -c '. scripts/package-lib.sh; echo "${name}_${debver}_amd64.deb $name-$rpmver-$rpmrel.x86_64.rpm $name-$apkver-r$apkrel.apk"')"
    # The names are words on purpose.
    # shellcheck disable=SC2086
    set -- $files "$1"
    mkdir -p "$tree/dist/client/alpine/x86_64"
    : > "$tree/dist/client/$1"
    : > "$tree/dist/client/$2"
    : > "$tree/dist/client/alpine/x86_64/$3"
    (cd "$tree" && PROGRAM=client VERSION=v0.5.35 REVISION=1 PACKAGE_DATE=20261112 UPGRADE_FROM="$4" \
        sh -c '. scripts/package-record.sh && write_package_record')
}

# $1 case name, $2 script, $3 the release the build recorded (empty: none), $4 the release that is
# the newest when the script runs, $5 the release the script must download, $6 yes when it must
# have asked for the newest release.
starts_from() {
    build "$3"
    printf '%s\n' "$4" > "$stand/latest"
    : > "$stand/calls"
    # The status of the script does not matter: upgrade-test.sh ends in its first container.
    (cd "$tree" && STAND_IN="$stand" PATH="$stand/bin:$PATH" PROGRAM=client PLATFORM=linux/amd64 \
        sh "scripts/$2" > "$work/out" 2>&1) || true
    asked=no
    if grep -q '/releases/latest' "$stand/calls"; then asked=yes; fi
    downloads="$(grep -c '/releases/download/' "$stand/calls" || true)"
    wrong="$(grep '/releases/download/' "$stand/calls" | grep -vc "/releases/download/$5/" || true)"
    if [ "$downloads" -gt 0 ] && [ "$wrong" -eq 0 ] && [ "$asked" = "$6" ]; then
        printf 'ok   %s: %s downloads from %s, asked for the newest release: %s\n' "$1" "$downloads" "$5" "$asked"
    else
        printf 'FAIL %s: %s downloads, %s of them from another release than %s, asked for the newest release: %s (want %s)\n' \
            "$1" "$downloads" "$wrong" "$5" "$asked" "$6"
        sed 's/^/     /' "$work/out"
        failed=$((failed + 1))
    fi
}

for script in lifecycle-repo.sh upgrade-test.sh; do
    starts_from "$script: a release made after the build is not the one to start from" \
        "$script" v0.5.35 v0.5.36 v0.5.35 no
    starts_from "$script: a build that recorded none starts from the newest release" \
        "$script" "" v0.5.36 v0.5.36 yes
done

# lifecycle-test.sh reads the tag that lifecycle-repo.sh wrote down, so that is the tag to prove.
build v0.5.35
printf '%s\n' v0.5.36 > "$stand/latest"
(cd "$tree" && STAND_IN="$stand" PATH="$stand/bin:$PATH" PROGRAM=client PLATFORM=linux/amd64 \
    sh scripts/lifecycle-repo.sh > "$work/out" 2>&1) || true
written="$(cat "$tree/dist/lifecycle/client/published" 2>/dev/null || true)"
if [ "$written" = "TAG=v0.5.35" ]; then
    echo "ok   lifecycle-repo.sh: the tag written down for the lifecycle test is the recorded one"
else
    printf 'FAIL lifecycle-repo.sh: the tag written down is "%s"\n' "$written"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "upgrade from: all cases as expected"
