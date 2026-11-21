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

# The program of every process that runs in the system $1, one a line: the file the kernel says it runs
# (/proc has it on every Linux system), also when the file was removed, which the kernel marks with a
# suffix that is cut off here, so that a removed program is named as it was. A process the kernel does
# not give a file (its own threads) has no line.
running_programs() {
    # The script is for the shell that sh -c starts, which reads its own variables.
    # shellcheck disable=SC2016
    on_system "$1" sh -c '
        for dir in /proc/[0-9]*; do
            program_file="$(readlink "$dir/exe" 2>/dev/null)" || continue
            echo "${program_file% (deleted)}"
        done'
}
