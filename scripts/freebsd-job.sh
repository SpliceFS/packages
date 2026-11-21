#!/bin/sh
# Runs inside the FreeBSD build machine as root, started by the first-boot script. The machine
# is amd64 and its disk has pkg set up already. The job builds the packages for amd64 and arm64
# with FreeBSD's own tools, installs the amd64 one and removes it again, with its links. Of the service it
# proves, for every program, what the package test (scripts/package-test-steps.sh) does not: the install
# message, an upgrade that leaves a running service running, and the remove message. It starts the service
# for that. A program whose check-lib.sh sets expected_user gets every service check besides: it installs
# idle, the documented commands turn it on and start it, it runs as that user, and removing the package
# stops it and leaves rc.conf alone. The arm64 package is built for its ABI and not installed. What "the
# service works" means for this program comes from check-lib.sh in the input folder
# (programs/<program>/freebsd/check-lib.sh): answers, expected_user for the full checks, and extra_checks
# when the program has checks of its own.
#
# It also builds the signed package repository. The input archive on the fourth disk holds
# keys/splicefs.rsa(.pub) and the packages published before (repo/FreeBSD:<major>:<cpu>/All/).
# The output gets repo/FreeBSD:<major>:<cpu>/ with the new package and the catalog of all
# packages that pkg repo signed. The package of this machine is installed from that repository with the signature
# check on, and a repository signed with another key must be refused.
#
#   freebsd-job.sh <input folder> <output folder> <package name> <program> <package version> <program version>
#                  <upgrade package version>

# expected_user and answers are set by check-lib.sh of the program, which ShellCheck cannot follow.
# shellcheck disable=SC2154
set -eu
in="$1"
out="$2"
name="$3"
program="$4"
version="$5"
program_version="$6"
upgrade_version="$7"
mkdir -p "$out"

# Prints how long the phase that just ended took. timing.sh is not used: this script runs
# from the job folder on FreeBSD, where no other file of the repository is.
phase_start="$(date +%s)"
phase_done() {
    phase_now="$(date +%s)"
    echo "[time] $1: $((phase_now - phase_start))s"
    phase_start="$phase_now"
}

# Everything before this point, the boot and the first-boot setup, is the time since boot.
boot_sec="$(sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\).*/\1/p')"
if [ -n "$boot_sec" ]; then echo "[time] machine boot and first-boot setup: $((phase_start - boot_sec))s"; fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# The file is the one of the program being packaged, so there is no fixed file to follow.
# shellcheck source=/dev/null
. "$in/check-lib.sh"

# A program whose check-lib.sh sets expected_user gets every service check. The service of a program
# without it is proved by the package test (scripts/package-test-steps.sh), so it gets only the checks
# that test does not make: the install and remove messages and the upgrade under a running service.
service_checks=no
if [ -n "${expected_user:-}" ]; then service_checks=yes; fi
service_step() {
    if [ "$service_checks" = yes ]; then "$@"; fi
}

major="$(freebsd-version -u | cut -d. -f1)"

# plist is the packing list the host made from program.conf and config-folders
# (package_freebsd_plist in scripts/package-lib.sh). The programs the package installs are its
# bin/ lines and the folders the package owns are its @dir lines, so this job reads them from
# there and lists nothing itself.
programs="$(sed -n 's|^bin/||p' "$in/plist")"

# links is "<link> <target>" a line, the links of the package as the host made them from the
# links file of the program (package_link_list in scripts/package-lib.sh).

# One package per CPU type. goarch is how the build names the binary, abiarch how pkg names
# the CPU type in an ABI string, and the package of version $3 is written into the folder $4.
build() {
    goarch="$1"
    abiarch="$2"
    package_version="$3"
    package_folder="$4"
    stage="/tmp/stage-$goarch"
    rm -rf "$stage"
    install -d "$stage/usr/local/bin" "$stage/usr/local/etc/rc.d"
    sed -n 's/^@dir //p' "$in/plist" | while read -r folder; do
        install -d "$stage/usr/local/$folder"
    done
    for each in $programs; do
        install -m 0755 "$in/$each-$goarch" "$stage/usr/local/bin/$each"
    done
    install -m 0755 "$in/$program.rc" "$stage/usr/local/etc/rc.d/$program"
    while read -r link target; do
        install -d "$stage$(dirname "$link")"
        ln -s "$target" "$stage$link"
    done < "$in/links"
    sed -e "s|@NAME@|$name|" -e "s|@PROGRAM@|$program|g" -e "s|@VERSION@|$package_version|" \
        -e "s|@ABI@|FreeBSD:$major:$abiarch|" "$in/manifest.in" > "/tmp/manifest-$goarch"
    mkdir -p "$package_folder"
    osversion="$(uname -K)"
    pkg -o ABI="FreeBSD:$major:$abiarch" -o OSVERSION="$osversion" create \
        -M "/tmp/manifest-$goarch" -p "$in/plist" -r "$stage" -o "$package_folder"
}
build amd64 amd64 "$version" "$out/FreeBSD-$major-amd64"
phase_done "build the amd64 package"
build arm64 aarch64 "$version" "$out/FreeBSD-$major-aarch64"
phase_done "build the arm64 package"

package="$out/FreeBSD-$major-amd64/$name-$version.pkg"
[ -f "$package" ] || fail "pkg create did not write $package"
pkg info -F "$package" > "$out/info-amd64.txt"

# The signed repository. The input archive is a raw disk, so it is unpacked onto the
# filesystem first. pkg refuses a private key that others can read, and a file on the job
# disk cannot be given a mode, so the keys are copied to a folder of their own.
input_dir=/tmp/input
keys=/tmp/keys
mkdir -p "$input_dir" "$keys"
tar -xf /dev/vtbd3 -C "$input_dir" || fail "cannot read the input archive"
install -m 0600 "$input_dir/keys/splicefs.rsa" "$keys/splicefs.rsa"
install -m 0644 "$input_dir/keys/splicefs.rsa.pub" "$keys/splicefs.rsa.pub"
for abiarch in amd64 aarch64; do
    folder="$out/repo/FreeBSD:$major:$abiarch"
    mkdir -p "$folder/All"
    # Only the packages are taken over: the catalog is made again, so that it holds only what
    # this run wrote.
    if [ -d "$input_dir/repo/FreeBSD:$major:$abiarch/All" ]; then
        cp -R "$input_dir/repo/FreeBSD:$major:$abiarch/All/." "$folder/All/"
    fi
    cp "$out/FreeBSD-$major-$abiarch/$name-$version.pkg" "$folder/All/"
    # rsa: names the kind of key, as pkg 2 wants it; the catalog files then carry a signature.
    pkg repo "$folder" "rsa:$keys/splicefs.rsa" || fail "pkg repo could not sign the catalog of $folder"
    [ -f "$folder/meta.conf" ] || fail "pkg repo did not write $folder/meta.conf"
done
phase_done "unpack the input and sign the repositories"
repo_folder="$out/repo/FreeBSD:$major:amd64"

# Writes a repository configuration: <file> <repository name> <folder>.
write_repo_conf() {
    printf '%s: {\n  url: "file://%s",\n  signature_type: "pubkey",\n  pubkey: "%s",\n  enabled: yes\n}\n' \
        "$2" "$3" "$keys/splicefs.rsa.pub" > "$1"
}

# Waits until the command given succeeds, at most $1 seconds. Sets wait_status to 0 when it
# did and to 1 when the time ran out, and never fails itself, so that the caller reports the
# timeout (a function used as a condition runs with set -e off).
wait_for() {
    limit="$1"
    shift
    n=0
    wait_status=0
    until "$@" >/dev/null 2>&1; do
        n=$((n + 1))
        if [ "$n" -ge "$limit" ]; then
            wait_status=1
            return 0
        fi
        sleep 1
    done
}
# What a person would look at first when the service misbehaves.
show() {
    service "$program" status || true
    ls -la "/var/run/$program" || true
    # pgrep prints no column header and no jail column, which are what a person looks for here.
    # shellcheck disable=SC2009
    ps axww -o pid,jid,user,command | grep -e "$program" -e '^ *PID' | grep -v grep || true
    tail -n 30 "/var/log/$program.log" 2>/dev/null || true
}

# The program says in its log what it did. Counting the lines before a signal lets a check
# look at what was written after it and nothing older.
service_log="/var/log/$program.log"

# Status 0 when the program logged, after the first $1 lines of its log, that it applied the
# configuration. A reload that failed logs "configuration not applied", which does not match.
reload_logged() {
    tail -n +"$(($1 + 1))" "$service_log" | grep -q 'configuration applied'
}

# Reloads the service and proves that the reload happened and that the service works after
# it. The signal is asynchronous and the old process keeps answering until the program acts
# on it, so an answer alone proves nothing: the reload is done when the program logs that it
# applied the configuration. The limit is only a safety stop for a reload that never happens.
reload_limit=20
reload_works() {
    lines_before="$(wc -l < "$service_log")"
    service "$program" reload || fail "reload failed"
    wait_for "$reload_limit" reload_logged "$lines_before"
    [ "$wait_status" -eq 0 ] || { show; fail "the service did not log that it applied the configuration after a reload"; }
    wait_for 10 answers
    [ "$wait_status" -eq 0 ] || { show; fail "the service does not do its job after a reload"; }
}

# The package is installed from the signed repository, as a person would, and from no other
# repository: -r names ours, so the public FreeBSD ones are not asked.
mkdir -p /usr/local/etc/pkg/repos
write_repo_conf /usr/local/etc/pkg/repos/splicefs.conf splicefs "$repo_folder"
pkg update -r splicefs
pkg_output=/tmp/pkg-output
# Runs pkg and shows what it said. The output is kept in $pkg_output, because the messages of
# the package are part of what a person gets and the checks read them back.
pkg_run() {
    pkg "$@" > "$pkg_output" 2>&1 || { cat "$pkg_output"; fail "pkg $1 failed"; }
    cat "$pkg_output"
}
pkg_run install -y -r splicefs "$name"
phase_done "update the repository and install the package"
for each in $programs; do
    [ -x "/usr/local/bin/$each" ] || fail "$each is not installed"
    "/usr/local/bin/$each" --version | grep -qF "$program_version" ||
        fail "$each --version does not report $program_version"
done
# Every link of the package leads to an installed program: for the client that is the mount
# helper, which mount(8) runs when the line of /etc/fstab names it with mountprog=.
while read -r link target; do
    [ -L "$link" ] || fail "$link is not a link after the install"
    found="$(readlink "$link")"
    [ "$found" = "$target" ] || fail "$link leads to $found, not to $target"
    [ -x "$target" ] || fail "$link leads to $target, which is not a program"
done < "$in/links"
# Installing only installs: the service is neither turned on nor running until the
# administrator does it. pkg ends every process an install script leaves behind, so a package could
# not start its service anyway. onestatus asks even of a service that is not enabled.
check_service_idle_after_install() {
    if service "$program" enabled; then fail "the service is enabled after the install"; fi
    if service "$program" onestatus >/dev/null 2>&1; then fail "the service is running after the install"; fi
    if grep -qs "^${program}_enable=" /etc/rc.conf; then fail "the install set ${program}_enable in rc.conf"; fi
    echo "installed: not enabled, not running"
}

# The install message is part of what a person gets: it says how to turn the service on and start it.
# It is read from the output of the install, so no other pkg run may come between.
check_install_message() {
    grep -qF "sysrc ${program}_enable=YES && service $program start" "$pkg_output" ||
        fail "the install message does not say how to turn the service on and start it"
    echo "installed: the message says how to turn the service on and start it"
}

# The two commands of the install message, in its order, and the wait for the service to do its job.
start_service() {
    sysrc "${program}_enable=YES" || fail "sysrc could not turn the service on"
    service "$program" enabled || fail "the service is not enabled after sysrc"
    service "$program" start || { show; fail "the service did not start"; }
    wait_for 20 service "$program" status
    [ "$wait_status" -eq 0 ] || { show; fail "the service is not running after its start"; }
    wait_for 20 answers
    [ "$wait_status" -eq 0 ] || { show; fail "the service does not do its job after its start"; }
    echo "turned on and started as the message says, answering"
}

# The running service runs as its own user, and reloads and restarts.
check_service_running() {
    service_pid="$(cat "/var/run/$program/$program.pid")"
    owner="$(ps -o user= -p "$service_pid")"
    [ "$owner" = "$expected_user" ] || fail "the service runs as '$owner', not as $expected_user"
    reload_works
    service "$program" restart >/dev/null || fail "restart failed"
    wait_for 20 answers
    [ "$wait_status" -eq 0 ] || { show; fail "the service does not do its job after a restart"; }
    echo "running as $expected_user, reload and restart work"
}

# An upgrade leaves a running service running and never changes rc.conf. The package cannot
# restart the service, because pkg ends every process a package script starts, so the running
# program keeps its old version until the administrator restarts it, and the upgrade message
# says so. The new package is the same version with port revision 1 (the host writes its version,
# argument 7), in a repository of its own so that the published one stays as it is; pkg takes it
# as an upgrade of the installed one.
check_upgrade_under_running_service() {
    upgrade_folder=/tmp/upgrade-repo
    rm -rf "$upgrade_folder"
    build amd64 amd64 "$upgrade_version" "$upgrade_folder/All"
    pkg repo "$upgrade_folder" "rsa:$keys/splicefs.rsa" || fail "pkg repo could not sign the catalog of $upgrade_folder"
    write_repo_conf /usr/local/etc/pkg/repos/splicefsupgrade.conf splicefsupgrade "$upgrade_folder"
    pkg update -r splicefsupgrade
    pkg_run upgrade -y -r splicefsupgrade "$name"
    installed_version="$(pkg query %v "$name")"
    [ "$installed_version" = "$upgrade_version" ] || fail "the package is $installed_version, not upgraded to $upgrade_version"
    service "$program" status || { show; fail "the upgrade stopped the running service"; }
    wait_for 10 answers
    [ "$wait_status" -eq 0 ] || { show; fail "the service does not do its job after an upgrade"; }
    service "$program" enabled || fail "the upgrade turned the service off"
    grep -qF "service $program restart" "$pkg_output" || fail "the upgrade message does not say how to restart the service"
    # The restart the message names runs the new files.
    service "$program" restart >/dev/null || fail "restart after the upgrade failed"
    wait_for 20 answers
    [ "$wait_status" -eq 0 ] || { show; fail "the service does not do its job after the restart that follows an upgrade"; }
    echo "upgraded: the running service kept running, rc.conf stayed, the message says how to restart"
    phase_done "upgrade the package under a running service"
}

# Removing the package stops the service and leaves nothing running. rc.conf is the
# administrator's: the setting stays until the administrator deletes it.
check_service_after_removal() {
    # answers is one command whose status is the answer, so running it without set -e changes nothing.
    # shellcheck disable=SC2310
    if answers; then fail "the service still answers after the package was removed"; fi
    # The stop of the removal runs the stop_postcmd of the rc script, which takes the run folder away.
    [ ! -e "/var/run/$program" ] || { show; fail "stopping the service left /var/run/$program behind"; }
    grep -qs "^${program}_enable=" /etc/rc.conf || fail "the removal deleted ${program}_enable from rc.conf"
    echo "removed: the service stopped and rc.conf was left alone"
}

# The remove message says how to delete the setting, and the command does. It is read from the output
# of the removal, so no other pkg run may come between.
check_remove_message() {
    grep -qF "sysrc -x ${program}_enable" "$pkg_output" || fail "the remove message does not say how to delete the setting"
    sysrc -x "${program}_enable" || fail "sysrc could not delete the setting"
    if grep -qs "^${program}_enable=" /etc/rc.conf; then fail "sysrc -x left ${program}_enable in rc.conf"; fi
    echo "removed: the message says how to delete the setting, and sysrc -x does"
}

service_step check_service_idle_after_install
check_install_message
start_service
service_step check_service_running
phase_done "start the service and check it"

# What only this program has to prove, with the service running and answering.
if command -v extra_checks >/dev/null 2>&1; then
    extra_checks
    phase_done "check what only this program needs"
fi

check_upgrade_under_running_service

# Removing the package takes the programs and the links away.
pkg_run delete -y "$name"
service_step check_service_after_removal
for each in $programs; do
    [ ! -e "/usr/local/bin/$each" ] || fail "remove left $each behind"
done
while read -r link _; do
    [ ! -L "$link" ] || fail "remove left the link $link behind"
done < "$in/links"
check_remove_message
phase_done "remove the package"

# A repository that is not signed with our key is refused. Two copies of the repository are
# made, one signed again with a key made here and one not signed at all, and the package must
# not install from either while the configuration names our public key. pkg update reports
# success even when it throws a catalog away for its signature, so the install is what is
# tested. Each copy has its own name and its own configuration folder, so that it is the only
# repository pkg knows and the good catalog fetched above cannot stand in for it. The package
# was removed above, so an install has something to do.
( umask 077 && openssl genrsa -out /tmp/other.rsa 2048 2>/dev/null )
for kind in otherkey unsigned; do
    bad_folder="/tmp/bad-$kind"
    bad_conf="/tmp/bad-$kind-conf"
    rm -rf "$bad_folder" "$bad_conf"
    mkdir -p "$bad_folder" "$bad_conf"
    cp -R "$repo_folder/All" "$bad_folder/"
    if [ "$kind" = otherkey ]; then
        pkg repo "$bad_folder" rsa:/tmp/other.rsa >/dev/null
    else
        pkg repo "$bad_folder" >/dev/null
    fi
    write_repo_conf "$bad_conf/bad.conf" "splicefs$kind" "$bad_folder"
    pkg -o REPOS_DIR="$bad_conf" update -f -r "splicefs$kind" >/dev/null 2>&1 || true
    # pkg is a program here, so set -e is not off inside it.
    if pkg -o REPOS_DIR="$bad_conf" install -y -r "splicefs$kind" "$name" >/dev/null 2>&1; then
        fail "the package installed from a repository that is $kind"
    fi
done
echo "repository: signed catalog accepted; one signed with another key and an unsigned one refused"
phase_done "refuse the repositories with a wrong signature"

# The packages published before were needed for the catalog, and the host has them already:
# they do not travel back, so the result stays small however many versions are published.
for abiarch in amd64 aarch64; do
    old_packages="$input_dir/repo/FreeBSD:$major:$abiarch/All"
    [ -d "$old_packages" ] || continue
    for old in "$old_packages"/*.pkg; do
        [ -f "$old" ] || continue
        old_name="$(basename "$old")"
        [ "$old_name" = "$name-$version.pkg" ] || rm -f "$out/repo/FreeBSD:$major:$abiarch/All/$old_name"
    done
done
