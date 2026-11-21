#!/bin/sh
# FreeBSD (rc.d and pkg) functions of scripts/package-test-steps.sh; the file is sourced, so it runs
# nothing itself. The system is the FreeBSD machine, where the steps run as root with the programs
# of FreeBSD (scripts/freebsd-package-test.sh starts them). $name, $pkgver and $program come from
# scripts/package-lib.sh, and the harness says where a command runs (on_system:
# scripts/service-run-local.sh) before it sources this file.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

# The package files are in one folder for each program. The machine has no mount of the host, so the
# job unpacks its input into a folder of its own and says where (PACKAGE_FILES).
package_file() {
    echo "${PACKAGE_FILES:-/pkg}/$PROGRAM/$name-$pkgver.pkg"
}

# pkg add installs a package file and gets what it needs from the repositories of the system, as a
# person's install of a file does. The file carries no signature of its own: the new file is the
# build's, and a published file was proven by pkg fetch. What pkg says stays in the log: the machine
# has no other record of what an install did.
install_file() {
    on_system "$1" pkg add "$2"
}

install_package() {
    pkg_file="$(package_file)"
    on_system "$1" test -f "$pkg_file" || fail "$pkg_file does not exist; run make packages first"
    install_file "$1" "$pkg_file"
}

install_published_package() {
    install_file "$1" "$2"
}

# Prints the repository file as the setup script writes it: the function pkg_conf of the script $1
# (setup.sh.in, or the built one), for the address $2 of the site and the key file $3. The script
# cannot run whole, because its last line runs it and its functions write under /etc as root, so what
# is sourced is the rest of it, which only sets variables and defines functions. The address and the
# key are set after that, because the script sets its own. What people get and what the test fetches
# from are one text this way.
setup_repo_file_text() {
    sed '$d' "$1" >"$own/setup-functions.sh" || return 1
    # The variables are those of the shell that sh -c starts.
    # shellcheck disable=SC2016
    sh -c '. "$1"; BASE_URL=$2; PKG_KEY=$3; pkg_conf' sh "$own/setup-functions.sh" "$2" "$3"
}

# The published package of the program is not on the machine, which has no mount of the host: pkg
# fetches it from the public repository the way a person's pkg does after the setup script ran, with
# the signed catalog and the checksums of the packages checked. The repository file and the key are
# written as the setup script writes them (setup_repo_file_text) and taken away again, with the folders
# made for them, so that the new package is installed on a system that does not know the public
# repository, as on Linux. Prints the path of the file.
fetch_published_package() {
    config="${PKG_CONFIG_DIR:-/usr/local/etc/pkg}"
    key="$config/keys/splicefs.rsa.pub"
    repo_file="$config/repos/splicefs.conf"
    fetched="$own/published/$PROGRAM"
    made=""
    for folder in "$config" "$config/keys" "$config/repos"; do
        [ -d "$folder" ] || made="$folder${made:+ }$made"
        mkdir -p "$folder"
    done
    cp keys/splicefs.rsa.pub "$key"
    fetch_status=0
    # The file is written by a function whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if setup_repo_file_text setup.sh.in "$site_root" "$key" >"$repo_file"; then
        on_system "$1" pkg fetch -y -r "splicefs-$PROGRAM" -o "$fetched" "$name" >&2 || fetch_status=$?
    else
        fetch_status=1
    fi
    rm -f "$key" "$repo_file"
    # The folders go in the order they are listed: the inner ones first.
    for folder in $made; do rmdir "$folder"; done
    [ "$fetch_status" -eq 0 ] || return "$fetch_status"
    find "$fetched" -name "$name-*.pkg" | head -n 1
}

# Prints the version of the package file $2 that fetch_published_package got, in the words of a
# baseline file (scripts/package-test-program-lib.sh), read from the file itself. pkg fetch takes the
# newest package the repository lists at the moment it asks, which is not what the repository listed
# when the host read it earlier, so only the file says which version was fetched.
published_baseline_version() {
    pkg_version="$(on_system "$1" pkg query -F "$2" %v)" || return 1
    package_debver_of_pkgver "$pkg_version"
}

# pkg delete runs the pre-deinstall script of the package, which stops the service.
remove_package() {
    on_system "$1" pkg delete -y "$name" >/dev/null
}

# The file that defines the service: the package puts it there.
service_file() {
    echo "$servicedir/$program"
}

# onestatus asks of a service that is not enabled too.
service_active() {
    on_system "$1" service "$program" onestatus >/dev/null 2>&1
}

service_enabled() {
    on_system "$1" service "$program" enabled >/dev/null 2>&1
}

# The commands of the install message, which is also where they are written down.
service_enable() {
    on_system_as_root "$1" sysrc "${program}_enable=YES" >/dev/null
}

service_start() {
    on_system_as_root "$1" service "$program" start >/dev/null
}

service_start_enable() {
    service_enable "$1" && service_start "$1"
}

# NO and not sysrc -x: the removal of the setting is a step of its own, in the documented removal.
service_disable() {
    on_system_as_root "$1" sysrc "${program}_enable=NO" >/dev/null
}

# onestop works whether the service is enabled or not.
service_stop() {
    on_system_as_root "$1" service "$program" onestop >/dev/null
}

service_restart() {
    on_system_as_root "$1" service "$program" restart >/dev/null
}

# The process of the program, not daemon(8), which supervises it: the rc script names the file that
# holds its pid.
service_pid() {
    on_system "$1" cat "/var/run/$program/$program.pid"
}

service_user() {
    pid="$(service_pid "$1")" || return 1
    on_system "$1" ps -o user= -p "$pid"
}

# The IPv4 address of this machine that is not a loopback one, which the system itself knows: the
# first inet address of the interface the default route leaves through. FreeBSD's getent has no
# ahostsv4, and the name of the machine need not resolve. A line on stderr says what is missing, so
# that a log tells a machine without a network from a server that does not answer.
own_address() {
    # A command that fails gives no output, and the line below says so.
    # shellcheck disable=SC2312
    interface="$(route -n get default 2>/dev/null | awk '$1 == "interface:" { print $2; exit }')"
    [ -n "$interface" ] || { echo "own_address: no default route, so no interface to ask" >&2; return 1; }
    # shellcheck disable=SC2312
    address="$(ifconfig "$interface" inet 2>/dev/null | awk '$1 == "inet" { print $2; exit }')"
    [ -n "$address" ] || { echo "own_address: $interface has no inet address" >&2; return 1; }
    echo "$address"
}

service_report() {
    on_system "$1" service "$program" onestatus || true
    on_system "$1" tail -n 30 "/var/log/$program.log" || true
}

# Prints why an image cannot be tested, or nothing when it can.
skip_reason() {
    :
}
