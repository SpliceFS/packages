# shellcheck shell=sh
# Where the service test runs a command on a system that is a container, for the adapters that
# source scripts/service-systemd-lib.sh: inside the container, with docker exec, where every
# command is root's already.

on_system() {
    docker exec "$@"
}

on_system_as_root() {
    on_system "$@"
}

# The package file of package_file over the installed one, which is the same version, so the
# package manager of the system reinstalls it, as scripts/upgrade-package-lib.sh says. The
# container has the repository at /src. Usage: upgrade_package CONTAINER; $format and $VERSION
# are set by the harness.
upgrade_package() {
    docker exec -e DEBIAN_FRONTEND=noninteractive -w /src "$1" sh -c \
        '. scripts/upgrade-package-lib.sh; upgrade_package "$@"' sh "$format" "$VERSION" "$VERSION" file "$(package_file)"
}
