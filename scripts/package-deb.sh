#!/bin/sh
# Wraps the compiled programs of BIN (one folder for each system and CPU type, <os>-<arch>,
# holding the programs) into Debian packages of the program PROGRAM, one per CPU type, with
# dpkg-deb, and writes them to OUTPUT_DIR. SRC is the source tree of the program at this version:
# its LICENSE and documents are packaged. It runs in the Go image (make package-deb) and
# compiles nothing.
set -eu

out="${1:?usage: package-deb.sh OUTPUT_DIR}"
: "${BIN:?BIN is not set}"
# shellcheck source=package-lib.sh
. scripts/package-lib.sh
docs="$(package_docs)"

unit="$(mktemp)"
trap 'rm -f "$unit"' EXIT
package_unit "$unit"

for arch in amd64 arm64; do
    root="$(mktemp -d)"
    chmod 755 "$root"
    install -d "$root/DEBIAN" "$root$confdir"
    for folder in $confsubdirs; do install -d "$root$confdir/$folder"; done
    package_links "$root"
    # programs is set by program.conf, which ShellCheck cannot follow. The names hold no
    # spaces, so the list is split on purpose.
    # shellcheck disable=SC2154
    for built in $programs; do
        install -D -m 755 "$BIN/linux-$arch/$built" "$root/usr/bin/$built"
    done
    install -D -m 644 "$unit" "$root/usr/lib/systemd/system/$program.service"
    install -D -m 644 "$SRC/LICENSE" "$root/usr/share/doc/$name/copyright"
    # The names hold no spaces, so the list is split on purpose.
    # shellcheck disable=SC2086
    install -m 644 $docs "$root/usr/share/doc/$name/"

    size="$(du -sk "$root" | cut -f1)"
    sed -e "s/@NAME@/$name/" -e "s/@VERSION@/$debver/" -e "s/@ARCH@/$arch/" -e "s/@SIZE@/$size/" \
        "$defs/deb/control" > "$root/DEBIAN/control"
    for script in postinst prerm postrm; do
        install -m 755 "$defs/deb/$script" "$root/DEBIAN/$script"
    done

    dpkg-deb --root-owner-group --build "$root" "$out/${name}_${debver}_${arch}.deb" >/dev/null
    echo "built ${name}_${debver}_${arch}.deb"
done
