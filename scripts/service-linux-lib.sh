# shellcheck shell=sh
# The functions of the service test that every Linux system answers the same way, whatever its
# service manager: sourced by scripts/service-systemd-lib.sh (deb and rpm) and by
# scripts/service-test-apk.sh (Alpine). FreeBSD has its own in scripts/service-test-pkg.sh.

# The IPv4 address of this system that is not a loopback one: the name of the system resolves to it
# (the container runtime and every installer write the name into /etc/hosts). getent hosts is not
# used: on some systems it answers with ::1 for the name of the system.
own_address() {
    # A name that does not resolve gives no address, and the caller treats that as the answer.
    # shellcheck disable=SC2312
    getent ahostsv4 "$(uname -n)" | awk '$1 !~ /^127\./ { print $1; exit }'
}
