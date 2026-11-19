#!/bin/sh
# Debian and Ubuntu (systemd) functions of scripts/service-test.sh; the file is sourced, so
# it runs nothing itself. The service functions are those of scripts/service-systemd-lib.sh.
# $name, $debver and $program come from scripts/package-lib.sh and $platform from the harness.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

# shellcheck source=service-container-lib.sh
. scripts/service-container-lib.sh
# shellcheck source=service-systemd-lib.sh
. scripts/service-systemd-lib.sh

package_file() {
    echo "/pkg/${name}_${debver}_${platform#linux/}.deb"
}

install_package() {
    pkg="$(package_file)"
    docker exec "$1" test -f "$pkg" || fail "$pkg does not exist; run make packages first"
    # apt resolves the dependencies of a local file; dpkg -i alone would not.
    docker exec -e DEBIAN_FRONTEND=noninteractive "$1" sh -c \
        "apt-get update -qq && apt-get install -y -qq $pkg" >/dev/null
}

# The same file over the installed one: dpkg runs the upgrade path, with the old version's prerm
# and the new version's postinst.
upgrade_package() {
    pkg="$(package_file)"
    docker exec -e DEBIAN_FRONTEND=noninteractive "$1" dpkg -i "$pkg" >/dev/null
}

remove_package() {
    docker exec -e DEBIAN_FRONTEND=noninteractive "$1" apt-get remove -y -qq "$name" >/dev/null
}

# Prints why an image cannot be tested, or nothing when it can.
skip_reason() {
    :
}
