#!/bin/sh
# Debian and Ubuntu (apt) functions of scripts/package-test.sh, which sources this file after
# scripts/service-test-deb.sh; it runs nothing itself. The first argument is the container.
# $name comes from scripts/package-lib.sh, for the program the caller chose.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

# dpkg also knows a package that was removed and left its configuration behind.
package_installed() {
    docker exec "$1" sh -c 'dpkg-query -W -f="\${Status}" "$1" 2>/dev/null | grep -q "^install ok installed$"' sh "$name"
}

# The file of steps/ that uninstalls on this system.
uninstall_file() {
    echo steps/uninstall-apt.sh
}
