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
    echo "/pkg/$PROGRAM/$name-$rpmver-$rpmrel.$arch.rpm"
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

# The published package file $2 is signed by the release key, which is imported as the install page
# says, and the package manager checks the signature: no flag turns the check off. dnf checks a
# file only when it is told to; zypper always does.
install_published_package() {
    docker exec "$1" rpm --import /keys/splicefs.asc || return 1
    if docker exec "$1" sh -c 'command -v dnf' >/dev/null 2>&1; then
        docker exec "$1" dnf install -y -q --setopt=localpkg_gpgcheck=1 "$2" >/dev/null
    else
        docker exec "$1" zypper --non-interactive install "$2" >/dev/null
    fi
}

# The same file over the installed one: the upgrade path, with the new version's post and the old
# version's preun and postun.
upgrade_package() {
    reinstall_package_file "$1"
}

# dnf takes the packages the package needed along with it by its own setting; zypper does it only
# when told (the documented removal says so), so a system with either ends the same.
remove_package() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y -q "$1"
        else
            zypper --non-interactive remove --clean-deps "$1"
        fi' sh "$name" >/dev/null
}

# Prints why an image cannot be tested, or nothing when it can.
skip_reason() {
    :
}
