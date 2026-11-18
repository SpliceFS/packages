#!/bin/sh
# Wraps the compiled programs of BIN (one folder for each system and CPU type, <os>-<arch>,
# holding the programs) into rpm packages of the program PROGRAM, one per CPU type, with
# rpmbuild, and writes them to OUTPUT_DIR. SRC is the source tree of the program at this version:
# its LICENSE and documents are packaged. It runs in the rpm-build image (make package-rpm) and
# compiles nothing.
set -eu

out="${1:?usage: package-rpm.sh OUTPUT_DIR}"
: "${BIN:?BIN is not set}"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
docs="$(package_docs)"

unit="$(mktemp)"
link_root="$(package_link_tree)"
link_list="$(mktemp)"
trap 'rm -rf "$unit" "$link_root" "$link_list"' EXIT
package_unit "$unit"
# What %files lists for the links, one path to a line.
(cd "$link_root" && find . -type l | sed 's/^\.//') > "$link_list"

for arch in amd64 arm64; do
    case "$arch" in
        amd64) rpmarch=x86_64 ;;
        arm64) rpmarch=aarch64 ;;
        *) fail "no rpm CPU type for $arch" ;;
    esac
    top="$(mktemp -d)"
    package_script systemd "$defs/rpm/$name.spec" > "$top/$name.spec"
    rpmbuild -bb --quiet --target "$rpmarch" \
        --define "_topdir $top" \
        --define "pkg_name $name" \
        --define "pkg_version $rpmver" \
        --define "pkg_release $rpmrel" \
        --define "stage $BIN/linux-$arch" \
        --define "unit $unit" \
        --define "link_root $link_root" \
        --define "link_list $link_list" \
        --define "license_file $SRC/LICENSE" \
        --define "docs $docs" \
        "$top/$name.spec"
    cp "$top/RPMS/$rpmarch/$name-$rpmver-$rpmrel.$rpmarch.rpm" "$out/"
    echo "built $name-$rpmver-$rpmrel.$rpmarch.rpm"
done
