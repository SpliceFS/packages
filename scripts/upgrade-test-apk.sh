#!/bin/sh
# The Alpine part of the upgrade test (scripts/upgrade-test.sh), run inside a throwaway
# Alpine container.
# Usage: upgrade-test-apk.sh list PACKAGE          prints the listing of one package
#        upgrade-test-apk.sh upgrade OLD NEW       installs OLD, writes markers, installs
#                                                  NEW over it and checks the result
set -eu

# shellcheck source=upgrade-lib.sh
. scripts/upgrade-lib.sh

list_package() {
    work="$(mktemp -d)"
    # An apk is three archives one after the other (signature, package data, files); tar of
    # this system reads them all, and the first two leave only names that start with a dot.
    tar -xzf "$1" -C "$work"
    list_tree "$work"
    # The package data minus what changes in every build: the version, the size, the build
    # time, the checksum of the files, the version inside "provides" and the comment lines.
    grep -v -e '^#' -e '^pkgver = ' -e '^size = ' -e '^builddate = ' -e '^datahash = ' "$work/.PKGINFO" |
        sed -e 's/^\(provides = [^=]*\)=.*/\1/' -e 's/^/meta pkginfo /'
    # The install and remove scripts; the signature is made again in every build.
    for file in "$work"/.*; do
        case "$(basename "$file")" in
            . | .. | .PKGINFO | .SIGN.*) ;;
            *) script_line "$(basename "$file")" "$file" ;;
        esac
    done
    rm -rf "$work"
}

mode="${1:-}"
case "$mode" in
    list)
        list_package "${2:?usage: upgrade-test-apk.sh list PACKAGE}"
        ;;
    upgrade)
        old="${2:?usage: upgrade-test-apk.sh upgrade OLD NEW}"
        new="${3:?usage: upgrade-test-apk.sh upgrade OLD NEW}"
        # The old package is the published one, so apk checks its signature against the repository
        # key, as it does for a person who has installed that key; a package that was changed on the
        # way is refused. The new one is signed with the key of its own build, which no published
        # key is, so only that one is installed without the check. Both keys have the name apk looks
        # a key up by, splicefs.rsa.pub, so the repository key is taken away first: with it in
        # place apk calls the new signature bad, which --allow-untrusted does not let through.
        cp keys/splicefs.rsa.pub /etc/apk/keys/ || fail "apk upgrade: could not install the repository key"
        apk add -q "$old" || fail "apk upgrade: installing the old package failed (is it signed with the repository key?)"
        write_markers apk
        rm -f /etc/apk/keys/splicefs.rsa.pub
        upgrade_package apk "$PUBLISHED_VERSION" "$VERSION" file "$new" || fail "apk upgrade: installing the new package over the old one failed"
        init="/etc/init.d/$program"
        # The files the new package lists must all be there after the upgrade.
        listing="$(mktemp)"
        list_package "$new" > "$listing"
        user="$(sed -n 's/^command_user="\([^:"]*\).*/\1/p' "$init")"
        # apk list prints "NAME-VERSION-rN CPU {NAME} (LICENSE) [installed]" for a package.
        installed="$(apk list -I "$name")"
        installed="${installed%% *}"
        verify_upgrade apk "$user" "$listing" "$installed" "$name-$apkver-r$apkrel"
        ;;
    *)
        echo "usage: upgrade-test-apk.sh list PACKAGE | upgrade OLD NEW" >&2
        exit 2
        ;;
esac
