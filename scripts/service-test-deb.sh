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
    echo "/pkg/$PROGRAM/${name}_${debver}_${platform#linux/}.deb"
}

# Installs the package file $2 in the container $1. apt resolves the dependencies of a local file;
# dpkg -i alone would not.
install_file() {
    docker exec -e DEBIAN_FRONTEND=noninteractive "$1" sh -c \
        "apt-get update -qq && apt-get install -y -qq $2" >/dev/null
}

install_package() {
    pkg="$(package_file)"
    docker exec "$1" test -f "$pkg" || fail "$pkg does not exist; run make packages first"
    install_file "$1" "$pkg"
}

# The published package file $2. The release key is put where the install page puts it, for this
# install only: it is not there for the new package, nor when the system is compared with how it was.
# apt checks no signature of a file (it checks the index of a repository), so the signature of this
# file is proven by the signed index of the site, on the host (scripts/published-verify.sh).
install_published_package() {
    docker exec "$1" install -m 0644 /keys/splicefs.asc /etc/apt/keyrings/splicefs.asc || return 1
    install_status=0
    install_file "$1" "$2" || install_status=$?
    docker exec "$1" rm -f /etc/apt/keyrings/splicefs.asc || return 1
    return "$install_status"
}

# The same file over the installed one: the upgrade path, with the old version's prerm and the new
# version's postinst.
upgrade_package() {
    reinstall_package_file "$1"
}

remove_package() {
    docker exec -e DEBIAN_FRONTEND=noninteractive "$1" apt-get remove -y -qq "$name" >/dev/null
}

# Prints why an image cannot be tested, or nothing when it can.
skip_reason() {
    :
}
