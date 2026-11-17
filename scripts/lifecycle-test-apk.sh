#!/bin/sh
# Alpine (apk) functions of scripts/lifecycle-test.sh, which sources this file after
# scripts/service-test-apk.sh; it runs nothing itself. The first argument is the container.
# $name and $apkver come from scripts/package-lib.sh, for the version the caller chose.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

repo_refresh() {
    docker exec "$1" apk update -q >/dev/null
}

repo_install() {
    docker exec "$1" apk add -q "$name=$apkver-r0" >/dev/null
}

# Takes the newest version of the repository, the way a user upgrades.
repo_upgrade() {
    docker exec "$1" apk add -q -u "$name" >/dev/null
}

package_installed() {
    docker exec "$1" apk info -e "$name" >/dev/null 2>&1
}
