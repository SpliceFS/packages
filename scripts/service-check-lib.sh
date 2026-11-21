# shellcheck shell=sh
# The checks of a running service, shared by scripts/package-test-steps.sh and scripts/service-test-host.sh.
# Sourced after scripts/package-lib.sh (which also has wait_for, must and refuse, the helpers
# every test uses), the service check of the program (what "the service works" means) and the
# functions of the package format (scripts/service-test-<format>.sh); the first argument of every
# check is the system. expected_user, answers_text, answers, port, format and the service
# functions come from those files, which ShellCheck cannot follow.
# shellcheck disable=SC2154

# A server that runs a firewall (firewalld on Rocky Linux) refuses the port of the service until its
# owner opens it. Only a system that runs firewalld, with a program that listens on a port, has
# anything to open; every function below changes nothing in any other.
firewall_zone_dir=/etc/firewalld/zones
# The zone files firewalld writes when a port is opened for good: the zone, and the copy it keeps of
# the zone before the last change.
firewall_zone_names="public.xml public.xml.old"

firewall_in_use() {
    [ -n "${port:-}" ] && on_system "$1" firewall-cmd --state >/dev/null 2>&1
}

# The test opens the port the way a user of that system does, for good so that it holds after the reboot.
open_firewall() {
    firewall_in_use "$1" || return 0
    on_system_as_root "$1" firewall-cmd --permanent --add-port="$port/tcp" >/dev/null &&
        on_system_as_root "$1" firewall-cmd --reload >/dev/null
}

# What the test changes in the firewall is undone from a copy, not by the reverse command, which
# leaves a zone file behind that the system did not have. Before the port is opened, each of the zone
# files is copied into the folder $2, in the folder of the test, and a note is written for each that
# does not exist. Usage: save_firewall_zones SYSTEM FOLDER.
save_firewall_zones() {
    firewall_in_use "$1" || return 0
    mkdir -p "$2" || return 1
    for zone_name in $firewall_zone_names; do
        if on_system "$1" test -f "$firewall_zone_dir/$zone_name"; then
            on_system "$1" cp "$firewall_zone_dir/$zone_name" "$2/$zone_name" || return 1
        else
            : >"$2/$zone_name.missing" || return 1
        fi
    done
}

# Puts each zone file back byte for byte, deletes each that did not exist, and has firewalld read
# them. Usage: restore_firewall_zones SYSTEM FOLDER (the folder save_firewall_zones wrote).
restore_firewall_zones() {
    firewall_in_use "$1" || return 0
    for zone_name in $firewall_zone_names; do
        if [ -f "$2/$zone_name.missing" ]; then
            on_system "$1" rm -f "$firewall_zone_dir/$zone_name" || return 1
        else
            on_system "$1" cp "$2/$zone_name" "$firewall_zone_dir/$zone_name" || return 1
        fi
    done
    on_system_as_root "$1" firewall-cmd --reload >/dev/null
}

port_open_in_firewall() {
    firewall_in_use "$1" && on_system "$1" firewall-cmd --query-port="$port/tcp" >/dev/null
}

# Status 0 when the folder $2 is a mount of the system $1: every system's own mount table lists the folder
# between spaces ("splicefs on /mnt/media type ...").
mounted_at() {
    on_system "$1" mount | grep -qF " $2 "
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

# Enabling is a decision of its own, apart from starting: the service is on the list of what
# starts at boot, and the next check starts it.
check_enable() {
    service_enable "$1" || fail "the documented enable command failed"
    service_enabled "$1" || fail "the service is not enabled after the documented enable command"
    echo "ok: the documented enable command enables it"
}

check_start() {
    service_start "$1" || fail "the documented start command failed"
    must "the service is not active 20 seconds after the documented start command" wait_for 20 service_active "$1"
    echo "ok: the documented start command starts it"
}

# A program that mounts (mount_point of its service check) has its mount in the mount table while its service
# runs, and no longer after it stopped. A system whose mounts have a kind that its own tools can show (the
# adapter has check_mount_kind) shows it too.
check_mount_up() {
    [ -n "${mount_point:-}" ] || return 0
    must "$mount_point is not a mount while the service runs" mounted_at "$1" "$mount_point"
    echo "ok: $mount_point is a mount"
    if command -v check_mount_kind >/dev/null 2>&1; then check_mount_kind "$1" "$mount_point"; fi
}

check_documented_start() {
    service_start_enable "$1" || fail "the documented start command failed"
    service_enabled "$1" || fail "the service is not enabled after the documented start command"
    must "the service is not active 20 seconds after the documented start command" wait_for 20 service_active "$1"
    echo "ok: the documented start command enables and starts it"
}

check_user() {
    # Right after a start the main process can still be the service manager's fresh child, which is
    # root until it has become the program. A service that answers has become the program, so the
    # owner is read only after it answers: the order comes from that signal, not from time.
    must "the service does not do its job: expected that it $answers_text" wait_for 10 answers "$1"
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

# The system was restarted by whoever runs the steps, as a person restarts a machine: the service
# starts again on its own because it is enabled.
check_after_reboot() {
    # A service that is not back after a reboot says what its manager and its log know, which is all that is left of it.
    wait_for 60 active_and_answering "$1" || {
        service_report "$1"
        fail "the service is not active and answering 60 seconds after a reboot"
    }
    echo "ok: active and answering after a reboot, because it was enabled"
    check_mount_up "$1"
}

# A stopped service stays enabled, so that it comes back at the next boot: only the disable
# check turns that off.
check_stop() {
    service_stop "$1" || fail "stopping the service failed"
    must "the service is still active 10 seconds after it was stopped" wait_for 10 inactive "$1"
    refuse "the service still answers after it was stopped" answers "$1"
    # shellcheck disable=SC2310
    [ -z "${mount_point:-}" ] || refuse "$mount_point is still a mount after the service was stopped" mounted_at "$1" "$mount_point"
    echo "ok: stopped and silent"
}

check_disable() {
    service_disable "$1" || fail "the documented disable command failed"
    refuse "the service is still enabled after the documented disable command" service_enabled "$1"
    echo "ok: the service is not enabled"
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
