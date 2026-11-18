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
