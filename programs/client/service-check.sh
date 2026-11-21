# shellcheck shell=sh
# answers_text is read by scripts/package-test-steps.sh, which sources this file.
# shellcheck disable=SC2034
# Sourced by scripts/package-test-steps.sh and scripts/service-test-host.sh. It says what "the service
# works" means for this program; everything else in the service test is the same for every program.

# shellcheck source=../../scripts/test-config-lib.sh
. scripts/test-config-lib.sh

# The client listens on no network port. A person asks it for its state with the status
# command, which talks to the running service over its control socket (docs/configuration.md), and
# sees its mount: with the test configuration (programs/client/test-config.sh) the service does its job
# when the mount is up and the file of the share reads through it.
answers_text="answers the status command and reads $share_file through the mount"
# The folder the service mounts, which the steps find in the mount table after a start and a stop.
mount_point="$mount_target"
# The client of a release that has no cluster_key setting cannot be configured as the test configuration
# does, so the service of the published client is not started before the upgrade (step 1a) until a
# published release has the setting.
service_before_upgrade=no
# The client trusts the server by its cluster key, so the server has to serve a certificate the key
# signed before the client starts (step 4).
needs_cluster_certificate=yes

# The unit has no User= line on purpose: the control socket is readable only by the user
# the client runs as, and mount(8) helpers run as root, so the service runs as root.
# program and defs are set by scripts/package-lib.sh before it sources this file.
# shellcheck disable=SC2154
expected_user="$(sed -n 's/^User=//p' "$defs/systemd/$program.service")"
expected_user="${expected_user:-root}"

# Status 0 when "splicefsctl status" succeeds against the running service and the file of the share
# reads through the mount with the bytes the server holds. The status command exits with an error when
# it cannot reach the control socket, so only a running service passes; a read of a mount that does not
# answer would wait for ever, so it is given a limit, which ends it and is not waited for. It runs inside
# the system that runs the service, which the argument names and does not need.
answers() {
    splicefsctl status >/dev/null 2>&1 || return 1
    read_text="$(timeout 5 cat "$mount_target/$share_file" 2>/dev/null)"
    [ "$read_text" = "$share_text" ]
}

# The same on the machine that runs the service itself. The control socket is readable only by
# the user the client runs as, which is root, and the person who runs the test is not.
answers_here() {
    sudo splicefsctl status >/dev/null 2>&1
}
