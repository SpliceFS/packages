#!/bin/sh
# Alpine (apk) functions of scripts/lifecycle-test.sh, which sources this file after
# scripts/service-test-apk.sh; it runs nothing itself. The first argument is the container.
# $name, $apkver and $apkrel come from scripts/package-lib.sh, for the version the caller chose.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

repo_refresh() {
    docker exec "$1" apk update -q >/dev/null
}

repo_install() {
    docker exec "$1" apk add -q "$name=$apkver-r$apkrel" >/dev/null
}

package_installed() {
    docker exec "$1" apk info -e "$name" >/dev/null 2>&1
}

# The file of steps/ that uninstalls on this system.
uninstall_file() {
    echo steps/uninstall-apk.sh
}
