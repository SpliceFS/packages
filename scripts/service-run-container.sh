#!/bin/sh
# Where the service functions run a command on a system that is a container, for a script on the
# host of the container: inside it, with docker exec, where every command is root's already.
# scripts/service-run-local.sh is the same two functions for a script that runs inside the system.

on_system() {
    docker exec "$@"
}

on_system_as_root() {
    on_system "$@"
}

# The package file of package_file over the installed one, which is the same version, so the
# package manager of the system reinstalls it, as scripts/upgrade-package-lib.sh says. The
# container has the repository at /src. Usage: reinstall_package_file CONTAINER; $format and
# $VERSION are set by the harness.
# shellcheck disable=SC2154 # the harness that sources this file sets them
reinstall_package_file() {
    pkg="$(package_file)"
    docker exec -e DEBIAN_FRONTEND=noninteractive -w /src "$1" sh -c \
        '. scripts/upgrade-package-lib.sh; upgrade_package "$@"' sh "$format" "$VERSION" "$VERSION" file "$pkg"
}
