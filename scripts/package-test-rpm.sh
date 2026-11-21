#!/bin/sh
# Rocky Linux, Amazon Linux and openSUSE (dnf and zypper) functions of scripts/package-test.sh,
# which sources this file after scripts/service-test-rpm.sh; it runs nothing itself. The first
# argument is the container. $name comes from scripts/package-lib.sh, for the program the caller
# chose.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

package_installed() {
    docker exec "$1" rpm -q "$name" >/dev/null 2>&1
}

# The file of steps/ that uninstalls on this system: dnf or zypper, as for the other functions.
uninstall_file() {
    docker exec "$1" sh -c '
        if command -v dnf >/dev/null 2>&1; then echo steps/uninstall-dnf.sh; else echo steps/uninstall-zypper.sh; fi'
}
