#!/bin/sh
# Rocky Linux, Amazon Linux and openSUSE (dnf and zypper) functions of scripts/lifecycle-test.sh,
# which sources this file after scripts/service-test-rpm.sh; it runs nothing itself. The first
# argument is the container. $name and $rpmver come from scripts/package-lib.sh, for the
# version the caller chose.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

repo_refresh() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then dnf makecache -y -q; else zypper --non-interactive refresh; fi' >/dev/null
}

repo_install() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y -q "$1-$2"
        else
            zypper --non-interactive install "$1=$2"
        fi' sh "$name" "$rpmver" >/dev/null
}

# Takes the newest version of the repository, the way a user upgrades.
repo_upgrade() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then
            dnf upgrade -y -q "$1"
        else
            zypper --non-interactive update "$1"
        fi' sh "$name" >/dev/null
}

package_installed() {
    docker exec "$1" rpm -q "$name" >/dev/null 2>&1
}

# The file of steps/ that uninstalls on this system: dnf or zypper, as for the other functions.
uninstall_file() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then echo steps/uninstall-dnf.sh; else echo steps/uninstall-zypper.sh; fi'
}
