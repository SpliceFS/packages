# shellcheck shell=sh
# The checks of a running service, shared by scripts/service-test.sh and scripts/lifecycle-test.sh.
# Sourced after scripts/package-lib.sh (which also has wait_for, must and refuse, the helpers
# every test uses), the service check of the program (what "the service works" means) and the
# functions of the package format (scripts/service-test-<format>.sh); the first argument of every
# check is the container. expected_user, answers_text, answers, port, format and the service
# functions come from those files, which ShellCheck cannot follow.
# shellcheck disable=SC2154

# A server that runs a firewall (firewalld on Rocky Linux) refuses the port of the service
# until its owner opens it, so the test opens it the way a user of that system does, for good
# so that it holds after the reboot. A system without a running firewalld has nothing to open,
# and neither has a program that listens on no port.
open_firewall() {
    [ -n "${port:-}" ] || return 0
    docker exec "$1" sh -c '
        firewall-cmd --state >/dev/null 2>&1 || exit 0
        firewall-cmd --permanent --add-port="$1/tcp" >/dev/null && firewall-cmd --reload >/dev/null' sh "$port"
}

active_and_answering() {
    service_active "$1" && answers "$1"
}

inactive() {
    ! service_active "$1"
}

# Installing is not a decision to run the service. It happens inside the install command, so
# the state right after the install is the whole answer and nothing is waited for.
check_idle_after_install() {
    refuse "the service is enabled after the install" service_enabled "$1"
    refuse "the service is running after the install" service_active "$1"
    echo "ok: installed, not enabled and not running"
}

check_documented_start() {
    service_start_enable "$1" || fail "the documented start command failed"
    service_enabled "$1" || fail "the service is not enabled after the documented start command"
    must "the service is not active 20 seconds after the documented start command" wait_for 20 service_active "$1"
    echo "ok: the documented start command enables and starts it"
}

check_user() {
    user="$(service_user "$1")" || fail "cannot find the main process of the service"
    [ "$user" = "$expected_user" ] ||
        fail "the service runs as '$user', not as '$expected_user'"
    echo "ok: runs as $user"
}

check_answers() {
    must "the service does not do its job: expected that it $answers_text" wait_for 10 answers "$1"
    echo "ok: $answers_text"
}

check_restart() {
    service_restart "$1" || fail "the restart failed"
    must "the service is not active and answering 20 seconds after a restart" \
        wait_for 20 active_and_answering "$1"
    echo "ok: active and answering after a restart"
}

check_reboot() {
    docker restart "$1" >/dev/null || fail "docker restart failed"
    must "the service is not active and answering 60 seconds after a reboot" \
        wait_for 60 active_and_answering "$1"
    echo "ok: active and answering after a reboot, because it was enabled"
}

# An upgrade restarts a service that was running, so that it runs the new files. The process id
# changes only when it was restarted, which is how a restart is told from a service that was
# left alone. The second argument is the function that upgrades, called with the container.
check_upgrade_keeps_running() {
    before="$(service_pid "$1")" || fail "cannot find the main process before the upgrade"
    "$2" "$1" || fail "upgrading the package failed"
    must "the service is not active and answering 20 seconds after an upgrade" \
        wait_for 20 active_and_answering "$1"
    after="$(service_pid "$1")" || fail "cannot find the main process after the upgrade"
    [ "$after" != "$before" ] || fail "the upgrade did not restart the running service"
    service_enabled "$1" || fail "the upgrade turned the service off"
    echo "ok: an upgrade restarted the running service"
}

check_removal() {
    remove_package "$1" || fail "removing the package failed"
    check_stopped_after_removal "$1"
}

# What holds after the package is gone, however it was removed.
check_stopped_after_removal() {
    must "the service is still active after the package was removed" wait_for 10 inactive "$1"
    refuse "the service still answers after the package was removed" answers "$1"
    refuse "the service is still enabled after the package was removed" service_enabled "$1"
    # wait_booted is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_booted "$format" "$1" || fail "the service manager is not healthy after the package was removed"
    echo "ok: stopped, disabled and silent after the removal, the service manager is healthy"
}
