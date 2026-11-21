#!/bin/sh
# FreeBSD (rc.d and pkg) functions of scripts/package-test-steps.sh; the file is sourced, so it runs
# nothing itself. The system is the FreeBSD machine, where the steps run as root with the programs
# of FreeBSD (scripts/freebsd-package-test.sh starts them). $name, $pkgver and $program come from
# scripts/package-lib.sh, and the harness says where a command runs (on_system:
# scripts/service-run-local.sh) before it sources this file.
# shellcheck disable=SC2154 # those variables are set by the file that sources this one

# Where the machine's input put the package files, one folder for each program. The machine has
# no mount of the host, so the job unpacks its input into a folder of its own and says where.
package_files_dir() {
    echo "${PACKAGE_FILES:-/pkg}"
}

package_file() {
    echo "$(package_files_dir)/$PROGRAM/$name-$pkgver.pkg"
}

# pkg add installs a package file and gets what it needs from the repositories of the system, as a
# person's install of a file does. The file carries no signature of its own: the new file is the
# build's, and a published file was proven by pkg fetch.
install_file() {
    on_system "$1" pkg add "$2" >/dev/null
}

install_package() {
    pkg_file="$(package_file)"
    on_system "$1" test -f "$pkg_file" || fail "$pkg_file does not exist; run make packages first"
    install_file "$1" "$pkg_file"
}

install_published_package() {
    install_file "$1" "$2"
}

# The published package of the program is not on the machine, which has no mount of the host: pkg
# fetches it from the public repository the way a person's pkg does after the setup script ran, with
# the signed catalog and the checksums of the packages checked. The repository file and the key are
# written as the setup script writes them and taken away again, with the folders made for them, so
# that the new package is installed on a system that does not know the public repository, as on
# Linux. Prints the path of the file.
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
    cat >"$repo_file" <<REPO
splicefs-$PROGRAM: {
  url: "$site_root/$PROGRAM/freebsd/\${ABI}",
  mirror_type: "none",
  signature_type: "pubkey",
  pubkey: "$key",
  enabled: yes
}
REPO
    fetch_status=0
    on_system "$1" pkg fetch -y -r "splicefs-$PROGRAM" -o "$fetched" "$name" >&2 || fetch_status=$?
    rm -f "$key" "$repo_file"
    # The folders go in the order they are listed: the inner ones first.
    for folder in $made; do rmdir "$folder"; done
    [ "$fetch_status" -eq 0 ] || return "$fetch_status"
    find "$fetched" -name "$name-*.pkg" | head -n 1
}

# pkg delete runs the pre-deinstall script of the package, which stops the service.
remove_package() {
    on_system "$1" pkg delete -y "$name" >/dev/null
}

# The file that defines the service: the package puts it there.
service_file() {
    echo "/usr/local/etc/rc.d/$program"
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

service_report() {
    on_system "$1" service "$program" onestatus || true
    on_system "$1" tail -n 30 "/var/log/$program.log" || true
}

# Prints why an image cannot be tested, or nothing when it can.
skip_reason() {
    :
}
