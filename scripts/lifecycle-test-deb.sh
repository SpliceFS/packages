#!/bin/sh
# Debian and Ubuntu (apt) functions of scripts/lifecycle-test.sh, which sources this file after
# scripts/service-test-deb.sh; it runs nothing itself. The first argument is the container,
# and the repository is the one setup.sh registered. $name and $debver come from
# scripts/package-lib.sh, for the version the caller chose.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

repo_refresh() {
    docker exec "$1" apt-get update -qq >/dev/null
}

repo_install() {
    docker exec -e DEBIAN_FRONTEND=noninteractive "$1" apt-get install -y -qq "$name=$debver" >/dev/null
}

# Takes the newest version of the repository, the way a user upgrades.
repo_upgrade() {
    docker exec -e DEBIAN_FRONTEND=noninteractive "$1" apt-get install -y -qq --only-upgrade "$name" >/dev/null
}

# dpkg also knows a package that was removed and left its configuration behind.
package_installed() {
    docker exec "$1" sh -c 'dpkg-query -W -f="\${Status}" "$1" 2>/dev/null | grep -q "^install ok installed$"' sh "$name"
}
