#!/bin/sh
# Rocky Linux, Amazon Linux and openSUSE (systemd) functions of scripts/service-test.sh; the
# file is sourced, so it runs nothing itself. The service functions are those of
# scripts/service-systemd-lib.sh. $name, $rpmver and $program come from scripts/package-lib.sh
# and $platform from the harness.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

# shellcheck source=service-container-lib.sh
. scripts/service-container-lib.sh
# shellcheck source=service-systemd-lib.sh
. scripts/service-systemd-lib.sh

package_file() {
    # The file name carries the CPU type in rpm's own spelling.
    case "$platform" in
        linux/arm64) arch=aarch64 ;;
        linux/amd64) arch=x86_64 ;;
        *) fail "no rpm for platform $platform" ;;
    esac
    echo "/pkg/$name-$rpmver-$rpmrel.$arch.rpm"
}

# Installs the package file $2 in the container $1. The system's package manager resolves the
# dependencies of a local file; rpm -i alone would not. The build key is a throwaway, so zypper
# must be told to accept an unsigned file.
install_file() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y -q "$1"
        else
            zypper --non-interactive install --allow-unsigned-rpm "$1"
        fi' sh "$2" >/dev/null
}

install_package() {
    pkg="$(package_file)"
    docker exec "$1" test -f "$pkg" || fail "$pkg does not exist; run make packages first"
    install_file "$1" "$pkg"
}

# The published package file $2 is signed by the release key, which this system does not hold;
# dnf does not check a local file, and zypper is told as for the unsigned one.
install_published_package() {
    install_file "$1" "$2"
}

# The same file over the installed one: rpm runs the upgrade path, with the new version's post
# and the old version's preun and postun.
upgrade_package() {
    pkg="$(package_file)"
    docker exec "$1" rpm -U --replacepkgs "$pkg" >/dev/null
}

remove_package() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y -q "$1"
        else
            zypper --non-interactive remove "$1"
        fi' sh "$name" >/dev/null
}

# Prints why an image cannot be tested, or nothing when it can.
skip_reason() {
    :
}
