#!/bin/sh
# check: upgrade-from: the upgrade and lifecycle tests start from the newest package of the site the build recorded
# Test that the tests which start from the published packages (scripts/lifecycle-repo.sh and
# scripts/upgrade-test.sh) start from the newest package the package site serves, the one the build
# recorded (UPGRADE_FROM of dist/PROGRAM/version, which scripts/published-newest.sh read once), and
# that they download it from the site and from nowhere else: a release on GitHub holds no packages.
# A package published between the build and the test must change nothing: it would be newer than
# the new packages, and the upgrade a downgrade. Runs on the host, no Docker and no network (part
# of make check): curl and docker are stand-ins in a folder at the front of PATH. The stand-in
# curl serves the site from the folder "site" of the stand-ins (the index of the program is a file
# there; a package is any path that ends in .deb, .rpm or .apk, and holds its own address) and
# refuses every address that is not the site, which is where GitHub would be.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

stand="$work/stand-in"
mkdir -p "$stand/bin"
site=https://site.example
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
    https://site.example/*) path="${url#https://site.example/}" ;;
    *) exit 6 ;;
esac
if [ -f "$STAND_IN/site/$path" ]; then
    cp "$STAND_IN/site/$path" "$out"
else
    case "$path" in
        *.deb | *.rpm | *.apk) printf '%s\n' "$url" > "$out" ;;
        *) exit 22 ;;
    esac
fi
STUB
# docker: a pull works and nothing runs, so a test ends at its first container, after it has
# downloaded what it starts from.
cat > "$stand/bin/docker" <<'STUB'
#!/bin/sh
[ "$1" = pull ]
STUB
chmod 755 "$stand/bin/curl" "$stand/bin/docker"

# The part of the repository the two scripts read, in a tree of its own: they write into dist.
tree="$work/tree"
mkdir -p "$tree"
cp -R "$root/scripts" "$root/programs" "$root/packaging" "$tree/"
# Whether a downloaded package proves is scripts/published-verify-test.sh's subject. Here the script
# is a stand-in that notes the package it is asked about and answers with the status in the file
# verify-status of the stand-ins (0 when there is none).
cat > "$tree/scripts/published-verify.sh" <<'STUB'
#!/bin/sh
echo "$1" >> "$STAND_IN/verified"
exit "$(cat "$STAND_IN/verify-status" 2>/dev/null || echo 0)"
STUB

# Runs the script $1 of the tree, with the arguments that follow, for the client with the
# stand-ins in front.
run_script() {
    script="$1"
    shift
    (cd "$tree" && STAND_IN="$stand" PATH="$stand/bin:$PATH" PACKAGE_SITE="$site" PROGRAM=client \
        PLATFORM=linux/amd64 sh "scripts/$script" "$@")
}

# Writes the index of the site: the versions of the client, one for each argument.
publish() {
    index="$stand/site/client/apt/dists/stable/main/binary-amd64/Packages"
    mkdir -p "$(dirname "$index")"
    : > "$index"
    for version in "$@"; do
        printf 'Package: splicefs-client\nVersion: %s\nArchitecture: amd64\n\n' "$version" >> "$index"
    done
}

# Makes the packages of the client in the tree, as make packages leaves them, recorded as the
# version $1, with the published version $2 to upgrade from (empty: none). The packages hold the
# word new, so that a package that is taken for another with the same name shows.
build() {
    rm -rf "$tree/dist"
    # The inner shell expands $1, which is the version.
    # shellcheck disable=SC2016
    files="$(cd "$tree" && PROGRAM=client VERSION="$1" PACKAGE_DATE=20261112 \
        sh -c '. scripts/package-lib.sh; echo "${name}_${debver}_amd64.deb $name-$rpmver-$rpmrel.x86_64.rpm $name-$apkver-r$apkrel.apk"')"
    # The names are words on purpose.
    # shellcheck disable=SC2086
    set -- $files "$1" "$2"
    mkdir -p "$tree/dist/client/alpine/x86_64"
    echo new > "$tree/dist/client/$1"
    echo new > "$tree/dist/client/$2"
    echo new > "$tree/dist/client/alpine/x86_64/$3"
    (cd "$tree" && PROGRAM=client VERSION="$4" PACKAGE_DATE=20261112 UPGRADE_FROM="$5" \
        sh -c '. scripts/package-record.sh && write_package_record')
}

# $1 case name, $2 script, $3 the version of the build, $4 the published version the build
# recorded ("read" means the build read it from the site, as the workflows do; empty: none), $5 the
# published version the script must download, in the three formats, $6 yes when the script must
# have asked the site for its index, which a recorded version makes needless.
starts_from() {
    : > "$stand/calls"
    : > "$stand/verified"
    rm -f "$stand/verify-status"
    from="$4"
    if [ "$from" = read ]; then
        from="$(run_script published-newest.sh client)"
    fi
    build "$3" "$from"
    : > "$stand/calls"
    # The status of the script does not matter: upgrade-test.sh ends in its first container.
    # shellcheck disable=SC2310
    run_script "$2" > "$work/out" 2>&1 || true
    asked=no
    if grep -q 'Packages' "$stand/calls"; then asked=yes; fi
    grep -Eo 'https://[^ ]+\.(deb|rpm|apk)$' "$stand/calls" | LC_ALL=C sort > "$work/downloads" || true
    if [ -n "$5" ]; then printf '%s\n' "$5" | LC_ALL=C sort > "$work/want"; else : > "$work/want"; fi
    others="$(grep -o 'https://[^ ]*' "$stand/calls" | grep -vc "^$site/" || true)"
    if cmp -s "$work/downloads" "$work/want" && [ "$asked" = "$6" ] && [ "$others" -eq 0 ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: asked for the index: %s (want %s), addresses that are not the site: %s, downloads want\n' \
            "$1" "$asked" "$6" "$others"
        sed 's/^/     /' "$work/want"
        echo '     got'
        sed 's/^/     /' "$work/downloads"
        sed 's/^/     /' "$work/out"
        failed=$((failed + 1))
    fi
}

# What the site serves of the client at the published version 0.5.34, which is rpm release 1 and
# Alpine release r0: the pool of the deb, the folder of the CPU type of the others.
from_34="$site/client/apt/pool/main/s/splicefs-client/splicefs-client_0.5.34_amd64.deb
$site/client/rpm/x86_64/splicefs-client-0.5.34-1.x86_64.rpm
$site/client/alpine/x86_64/splicefs-client-0.5.34-r0.apk"
from_35="$site/client/apt/pool/main/s/splicefs-client/splicefs-client_0.5.35_amd64.deb
$site/client/rpm/x86_64/splicefs-client-0.5.35-1.x86_64.rpm
$site/client/alpine/x86_64/splicefs-client-0.5.35-r0.apk"

for script in lifecycle-repo.sh upgrade-test.sh; do
    # The release being published is newer than anything on the site, and its release on GitHub
    # holds no packages: the baseline is the newest package of the site.
    publish 0.5.33 0.5.34
    starts_from "$script: a new release starts from the newest package on the site" \
        "$script" v0.5.35 read "$from_34" no

    # The packages of a release that is published (a change to the packaging alone) start from
    # the package of that release.
    publish 0.5.34 0.5.35
    starts_from "$script: a published release starts from its own package" \
        "$script" v0.5.35 read "$from_35" no

    # A package published after the build is newer than the packages: not the one to start from.
    publish 0.5.34 0.5.35
    starts_from "$script: a package published after the build is not the one to start from" \
        "$script" v0.5.35 0.5.34 "$from_34" no

    publish 0.5.33 0.5.34
    starts_from "$script: a build that recorded none starts from the newest package on the site" \
        "$script" v0.5.35 "" "$from_34" yes
done

# Every package the tests start from is proven before it is used, by the path it has on the site.
publish 0.5.33 0.5.34
for script in lifecycle-repo.sh upgrade-test.sh; do
    starts_from "$script: the baseline is verified" "$script" v0.5.35 read "$from_34" no
    LC_ALL=C sort "$stand/verified" | tr '\n' ' ' > "$work/verified-sorted"
    read -r verified_sorted < "$work/verified-sorted" || true
    if [ "${verified_sorted:-}" = "alpine/x86_64/splicefs-client-0.5.34-r0.apk apt/pool/main/s/splicefs-client/splicefs-client_0.5.34_amd64.deb rpm/x86_64/splicefs-client-0.5.34-1.x86_64.rpm" ]; then
        echo "ok   $script: every baseline package went through the verification, by its site path"
    else
        printf 'FAIL %s: the packages verified were:\n' "$script"
        sed 's/^/     /' "$stand/verified"
        failed=$((failed + 1))
    fi
done

# A package that does not prove ends the test of its format, with a message that says so, and no
# container is started with it; the lifecycle test stops.
build v0.5.35 0.5.34
echo 1 > "$stand/verify-status"
status=0
# The status of the script is the answer here.
# shellcheck disable=SC2310
run_script upgrade-test.sh > "$work/out" 2>&1 || status=$?
grep -c 'FAIL .*: could not download and verify' "$work/out" > "$work/failures" || true
read -r failures < "$work/failures"
if [ "$status" -ne 0 ] && [ "$failures" -eq 3 ]; then
    echo "ok   upgrade-test.sh: a package that does not prove fails its format"
else
    printf 'FAIL upgrade-test.sh: a package that does not prove (status %s):\n' "$status"
    sed 's/^/     /' "$work/out"
    failed=$((failed + 1))
fi
status=0
# shellcheck disable=SC2310
run_script lifecycle-repo.sh > "$work/out" 2>&1 || status=$?
if [ "$status" -ne 0 ] && grep -q 'could not download and verify' "$work/out"; then
    echo "ok   lifecycle-repo.sh: a package that does not prove stops the test"
else
    printf 'FAIL lifecycle-repo.sh: a package that does not prove (status %s):\n' "$status"
    sed 's/^/     /' "$work/out"
    failed=$((failed + 1))
fi

# Nothing published: the upgrade test skips, and the lifecycle test, which starts from a published
# version, says so and stops. Once the build has read that nothing is published ("read" gives the
# word the version record keeps for it), no job asks the site again; a build that read nothing
# leaves the question to the tests.
publish
for read in read ""; do
    # starts_from sets asked itself, so the answer wanted has a name of its own.
    want_asked=no
    [ -n "$read" ] || want_asked=yes
    starts_from "upgrade-test.sh: nothing is published, nothing is downloaded (read by the build: ${read:-no})" \
        upgrade-test.sh v0.5.35 "$read" "" "$want_asked"
    if grep -q 'skip deb: no published version yet' "$work/out"; then
        echo "ok   upgrade-test.sh: nothing is published, the test skips"
    else
        printf 'FAIL upgrade-test.sh: nothing is published, but it did not skip:\n'
        sed 's/^/     /' "$work/out"
        failed=$((failed + 1))
    fi
    starts_from "lifecycle-repo.sh: nothing is published, nothing is downloaded (read by the build: ${read:-no})" \
        lifecycle-repo.sh v0.5.35 "$read" "" "$want_asked"
    if grep -q 'nothing is published' "$work/out"; then
        echo "ok   lifecycle-repo.sh: nothing is published, it says so"
    else
        printf 'FAIL lifecycle-repo.sh: nothing is published, but it did not say so:\n'
        sed 's/^/     /' "$work/out"
        failed=$((failed + 1))
    fi
done

# lifecycle-test.sh reads the version that lifecycle-repo.sh wrote down, so that is what to prove.
publish 0.5.33 0.5.34
build v0.5.35 0.5.34
# shellcheck disable=SC2310
run_script lifecycle-repo.sh > "$work/out" 2>&1 || true
written="$(cat "$tree/dist/lifecycle/client/published" 2>/dev/null || true)"
if [ "$written" = "TAG=v0.5.34" ]; then
    echo "ok   lifecycle-repo.sh: the version written down for the lifecycle test is the published one"
else
    printf 'FAIL lifecycle-repo.sh: the version written down is "%s"\n' "$written"
    failed=$((failed + 1))
fi

# A change to the packaging alone keeps the version, so a published package can have the name of
# a new one. The repository the lifecycle test installs from must hold the new one.
publish 0.5.33 0.5.34
build v0.5.34 0.5.34
# shellcheck disable=SC2310
run_script lifecycle-repo.sh > "$work/out" 2>&1 || true
kept="$(cat "$tree/dist/lifecycle/client/splicefs-client_0.5.34_amd64.deb" \
    "$tree/dist/lifecycle/client/splicefs-client-0.5.34-1.x86_64.rpm" \
    "$tree/dist/lifecycle/client/alpine/x86_64/splicefs-client-0.5.34-r0.apk" 2>/dev/null | tr '\n' ' ')"
if [ "$kept" = "new new new " ]; then
    echo "ok   lifecycle-repo.sh: a published package with the name of a new one does not replace it"
else
    printf 'FAIL lifecycle-repo.sh: the repository holds "%s", not the new packages\n' "$kept"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "upgrade from: all cases as expected"
