#!/bin/sh
# Alpine (OpenRC) functions of scripts/service-test.sh; the file is sourced, so it runs
# nothing itself. $name, $apkver and $program come from scripts/package-lib.sh and $platform
# from the harness.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

package_file() {
    case "$platform" in
        linux/arm64) arch=aarch64 ;;
        *) arch=x86_64 ;;
    esac
    echo "/pkg/$PROGRAM/alpine/$arch/$name-$apkver-r$apkrel.apk"
}

install_package() {
    pkg="$(package_file)"
    docker exec "$1" test -f "$pkg" || fail "$pkg does not exist; run make packages first"
    # The build key is a throwaway, so the signature cannot be checked here.
    docker exec "$1" apk add -q --allow-untrusted "$pkg" >/dev/null
}

# apk does nothing when the package file of the installed version is added again. The upgrade
# scripts run when a package is reinstalled from a repository, so the file is put in a
# repository of its own and fix --reinstall installs it from there.
upgrade_package() {
    pkg="$(package_file)"
    docker exec "$1" sh -c '
        repo=/tmp/service-test-repo
        arch="$(apk --print-arch)"
        mkdir -p "$repo/$arch"
        cp "$1" "$repo/$arch/"
        apk index --allow-untrusted -q -o "$repo/$arch/APKINDEX.tar.gz" "$repo/$arch"/*.apk 2>/dev/null
        apk fix --reinstall --allow-untrusted --no-network --repositories-file /dev/null \
            -X "$repo" -q "$2"' sh "$pkg" "$name" >/dev/null
}

# The published package file $2 is signed by the release key, which apk checks when it installs a
# file: the key is put in place for the install only. The new package is signed with the key of
# its own build, which has the same name, so the release key must be gone before it is installed.
install_published_package() {
    docker exec "$1" sh -c '
        cp /src/keys/splicefs.rsa.pub /etc/apk/keys/ || exit 1
        status=0
        apk add -q "$1" || status=$?
        rm -f /etc/apk/keys/splicefs.rsa.pub
        exit "$status"' sh "$2" >/dev/null
}

remove_package() {
    docker exec "$1" apk del -q "$name" >/dev/null
}

# The file that defines the service: the package puts it there.
service_file() {
    echo "/etc/init.d/$program"
}

service_active() {
    docker exec "$1" rc-service "$program" status >/dev/null 2>&1
}

service_enabled() {
    docker exec "$1" rc-update show default | grep -q "^ *$program "
}

# The commands of the install page, which is also where they are written down.
service_enable() {
    docker exec "$1" rc-update add "$program" default >/dev/null
}

service_start() {
    docker exec "$1" rc-service "$program" start >/dev/null
}

service_start_enable() {
    service_enable "$1" && service_start "$1"
}

service_disable() {
    docker exec "$1" rc-update del "$program" default >/dev/null
}

service_stop() {
    docker exec "$1" rc-service "$program" stop >/dev/null
}

service_restart() {
    docker exec "$1" rc-service "$program" restart >/dev/null
}

# The main process is the one that runs the program, not supervise-daemon, whose command
# line only mentions it. The process id is read from /proc, which every system has, whatever ps
# it ships.
service_pid() {
    docker exec "$1" sh -c '
        for dir in /proc/[0-9]*; do
            [ "$(readlink "$dir/exe" 2>/dev/null)" = "/usr/bin/$1" ] || continue
            echo "${dir#/proc/}"
            exit 0
        done
        exit 1' sh "$program"
}

service_user() {
    pid="$(service_pid "$1")" || return 1
    docker exec "$1" sh -c '
        uid="$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "/proc/$1/status")"
        getent passwd "$uid" | cut -d: -f1' sh "$pid"
}

service_report() {
    docker exec "$1" rc-service "$program" status || true
    docker exec "$1" tail -n 30 "/var/log/${program}.log" || true
}

# Prints why an image cannot be tested, or nothing when it can.
skip_reason() {
    :
}
