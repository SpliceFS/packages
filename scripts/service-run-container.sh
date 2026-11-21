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
