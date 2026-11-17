#!/bin/sh
# Wraps the compiled programs of BIN (one folder for each system and CPU type, <os>-<arch>,
# holding the programs) into Alpine packages of the program PROGRAM, one per CPU type, with
# abuild, and writes them to OUTPUT_DIR/alpine/<cpu>. SRC is the source tree of the program at
# this version: its LICENSE and documents are packaged. It runs in the apk-build image (make
# package-apk) and compiles nothing.
#
# abuild signs what it builds, here with the repository key in /keys (read-only), because
# apk finds the key to check a package by the name inside the package: splicefs.rsa.pub.
set -eu

out="${1:?usage: package-apk.sh OUTPUT_DIR}"
: "${BIN:?BIN is not set}"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
docs="$(package_docs)"

# The copy is made so the key is readable by abuild without touching the mode on the host.
keydir="$(mktemp -d)"
cp /keys/splicefs.rsa /keys/splicefs.rsa.pub "$keydir/"
chmod 600 "$keydir/splicefs.rsa"
export PACKAGER_PRIVKEY="$keydir/splicefs.rsa"

for arch in amd64 arm64; do
    case "$arch" in
        amd64) apkarch=x86_64 ;;
        arm64) apkarch=aarch64 ;;
        *) fail "no Alpine CPU type for $arch" ;;
    esac
    # abuild names the repository after the directory above the one holding the APKBUILD.
    work="$(mktemp -d)/splicefs/$name"
    mkdir -p "$work"
    cp "$defs/alpine/$name".* "$work/"
    sed -e "s/@NAME@/$name/" -e "s/@VERSION@/$apkver/" "$defs/alpine/APKBUILD" > "$work/APKBUILD"
    (
        cd "$work"
        # CARCH labels the package for the CPU type of the binary inside it; nothing is
        # compiled here, so no cross compiler is involved.
        CARCH="$apkarch" STAGE="$BIN/linux-$arch" DEFS="$OLDPWD/$defs" LICENSE_FILE="$SRC/LICENSE" \
            DOCS="$docs" REPODEST="$work/repo" abuild -F -q rootpkg
    )
    mkdir -p "$out/alpine/$apkarch"
    cp "$work/repo/splicefs/$apkarch/$name-$apkver-r0.apk" "$out/alpine/$apkarch/"
    echo "built alpine/$apkarch/$name-$apkver-r0.apk"
done
