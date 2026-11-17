# shellcheck shell=sh
# The checks of a running service, shared by scripts/service-test.sh and scripts/lifecycle-test.sh.
# Sourced after scripts/package-lib.sh, the service check of the program (what "the service
# works" means) and the functions of the package format (scripts/service-test-<format>.sh); the
# first argument of every check is the container. expected_user, answers_text, answers, port,
# format and the service functions come from those files, which ShellCheck cannot follow.
# shellcheck disable=SC2154

# Runs the command once a second until it succeeds or the given number of seconds is over.
wait_for() {
    limit="$1"
    shift
    waited=0
    until "$@"; do
        waited=$((waited + 1))
        [ "$waited" -lt "$limit" ] || return 1
        sleep 1
    done
}

# Ends this system's run with the message when the command fails. The command runs through
# "$@" because errexit is off in every check (see run_checks): each one is guarded
# explicitly, and its status is the answer.
must() {
    message="$1"
    shift
    "$@" || fail "$message"
}

# The same for a command that has to fail: ends the run with the message when it succeeds.
refuse() {
    message="$1"
    shift
    if "$@"; then fail "$message"; fi
}

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

check_starts_by_itself() {
    service_enabled "$1" || fail "the service is not enabled after the install"
    must "the service is not active 20 seconds after the install" wait_for 20 service_active "$1"
    echo "ok: enabled and active after the install, nobody started it"
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
    echo "ok: active and answering after a reboot, nobody started it"
}

check_removal() {
    remove_package "$1" || fail "removing the package failed"
    must "the service is still active after the package was removed" wait_for 10 inactive "$1"
    refuse "the service still answers after the package was removed" answers "$1"
    # wait_booted is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    wait_booted "$format" "$1" || fail "the service manager is not healthy after the package was removed"
    echo "ok: stopped and silent after the removal, the service manager is healthy"
}
