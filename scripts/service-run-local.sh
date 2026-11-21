#!/bin/sh
# Where the service functions run a command when the script is already inside the system, as
# scripts/package-test-steps.sh is: right here, as root, which is who it runs as. The first
# argument names the system for the functions that pass it on (scripts/service-check-lib.sh) and
# is not needed. scripts/service-run-container.sh is the same two functions for a script on the
# host of a container.

on_system() {
    shift
    "$@"
}

on_system_as_root() {
    on_system "$@"
}
