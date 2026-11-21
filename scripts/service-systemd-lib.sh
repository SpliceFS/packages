# shellcheck shell=sh
# The service functions of scripts/package-test-steps.sh (see the steps there) for a system whose
# service manager is systemd: the containers of the deb and rpm formats and the machine of CI.
# Sourced by the adapters of those (scripts/service-test-<format>.sh and
# scripts/service-test-host-deb.sh) after scripts/package-lib.sh, which says what $program is,
# and after the functions that say where a command runs, which differ between a script on the host
# of a container, a script inside the system and the machine itself:
#   on_system SYSTEM COMMAND [ARGUMENT...]          runs the command as an ordinary user
#   on_system_as_root SYSTEM COMMAND [ARGUMENT...]  runs the command as root
# (scripts/service-run-container.sh, scripts/service-run-local.sh, scripts/service-test-host-deb.sh)
# SYSTEM is the first argument that the checks of scripts/service-check-lib.sh pass on.
# $program is set by package-lib.sh, which ShellCheck cannot follow.
# shellcheck disable=SC2154

unit="$program.service"

# The file that defines the service: the package puts it there.
service_file() {
    echo "$servicedir/$unit"
}

service_active() {
    on_system "$1" systemctl is-active --quiet "$unit"
}

service_enabled() {
    on_system "$1" systemctl is-enabled --quiet "$unit"
}

# The commands of the install page, which is also where they are written down.
service_start_enable() {
    on_system_as_root "$1" systemctl enable --now "$unit"
}

# The same in two commands, for a person who enables the service first and starts it later.
service_enable() {
    on_system_as_root "$1" systemctl enable "$unit"
}

service_start() {
    on_system_as_root "$1" systemctl start "$unit"
}

service_disable() {
    on_system_as_root "$1" systemctl disable "$unit"
}

service_stop() {
    on_system_as_root "$1" systemctl stop "$unit"
}

service_restart() {
    on_system_as_root "$1" systemctl restart "$unit"
}

service_pid() {
    on_system "$1" systemctl show -p MainPID --value "$unit"
}

# Reads the owner of the running process from /proc, which every system has, whatever ps it ships.
service_user() {
    pid="$(service_pid "$1")" || return 1
    [ "${pid:-0}" -gt 0 ] || return 1
    # The script is for the shell that sh -c starts, which reads its own $1.
    # shellcheck disable=SC2016
    on_system "$1" sh -c '
        uid="$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "/proc/$1/status")"
        getent passwd "$uid" | cut -d: -f1' sh "$pid"
}

# The IPv4 address of this system that is not a loopback one: the name of the system resolves to it
# (the container runtime and every installer write the name into /etc/hosts). getent hosts is not
# used: on some systems it answers with ::1 for the name of the system.
own_address() {
    # A name that does not resolve gives no address, and the caller treats that as the answer.
    # shellcheck disable=SC2312
    getent ahostsv4 "$(uname -n)" | awk '$1 !~ /^127\./ { print $1; exit }'
}

service_report() {
    on_system "$1" systemctl status --no-pager --full "$unit" || true
    on_system_as_root "$1" journalctl -u "$unit" --no-pager -n 30 || true
}
