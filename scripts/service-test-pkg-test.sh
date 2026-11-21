#!/bin/sh
# check: service-test-pkg.sh: the FreeBSD adapter installs, fetches, starts, stops and removes with pkg, sysrc and service
# Test of scripts/service-test-pkg.sh and scripts/package-test-pkg.sh. pkg, sysrc, service and ps are
# stand-ins on the PATH that write their arguments to a file, so the test needs no FreeBSD and runs in
# milliseconds (part of make check). What the real tools do is proved in the machine
# (scripts/freebsd-package-test.sh).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# The folder of the steps, which they made before the adapter runs.
mkdir "$work/bin" "$work/own"
for tool in pkg sysrc service; do
    # The stand-in expands its own variables when it runs. A tool named in FAIL_TOOL fails.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\ncase " ${FAIL_TOOL:-} " in *" %s "*) exit 1 ;; esac\n' "$tool" "$tool" >"$work/bin/$tool"
done
# pkg fetch writes the file it was asked for below the folder of -o, as pkg does; pkg info -e
# answers from the file INSTALLED.
cat >"$work/bin/pkg" <<'STAND_IN'
#!/bin/sh
echo "pkg $*" >> "$CALLS"
case " ${FAIL_TOOL:-} " in *" pkg "*) exit 1 ;; esac
case "$1" in
    fetch)
        shift
        while [ "$1" != -o ]; do shift; done
        mkdir -p "$2/All"
        : >"$2/All/splicefs-server-1.2.2.pkg"
        # What pkg reads when it fetches, kept for the test to look at.
        cp "$PKG_CONFIG_DIR/repos/splicefs.conf" "$CALLS.repo"
        ;;
    info) [ -f "$INSTALLED" ] ;;
    add) echo "Installing $2" ;;
    *) ;;
esac
STAND_IN
cat >"$work/bin/ps" <<'STAND_IN'
#!/bin/sh
echo "ps $*" >> "$CALLS"
echo splicefs
STAND_IN
cat >"$work/bin/cat" <<'STAND_IN'
#!/bin/sh
case "$1" in
    /var/run/splicefsd/splicefsd.pid) echo 4242 ;;
    *) exec /bin/cat "$@" ;;
esac
STAND_IN
chmod 755 "$work"/bin/*

# $1 case name, $2 the calls wanted, one to a line, $3 the status wanted, then the shell text to run,
# which has the functions of the adapter. Nothing else may be called.
runs() {
    : >"$work/calls"
    status=0
    CALLS="$work/calls" INSTALLED="$work/installed" PATH="$work/bin:/usr/bin:/bin" PROGRAM=server name=splicefs-server \
        program=splicefsd pkgver=1.2.3 servicedir=/usr/local/etc/rc.d platform=freebsd/amd64 own="$work/own" site_root=https://packages.example.org \
        sh -c "fail() { echo \"\$*\" >&2; exit 1; }; . scripts/service-run-local.sh; . scripts/service-test-pkg.sh; . scripts/package-test-pkg.sh; $4" \
        >"$work/out" 2>&1 || status=$?
    got="$(cat "$work/calls")"
    if [ "$got" = "$2" ] && [ "$status" -eq "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" (status %s), got "%s" (status %s)\n' "$1" "$2" "$3" "$got" "$status"
        failed=$((failed + 1))
    fi
}

# The output of the last runs, both streams, holds the text $2: what pkg add says is in the log of the
# steps, so that a failure of a later step can be read against it.
said() {
    if grep -qF "$2" "$work/out"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: "%s" is not in "%s"\n' "$1" "$2" "$(cat "$work/out" || true)"
        failed=$((failed + 1))
    fi
}

# The text is for the shell that sh -c starts, which expands it.
# shellcheck disable=SC2016
runs "the package file is where the machine's input puts it, by the name and version of the package" "" 0 \
    '[ "$(PACKAGE_FILES=/in package_file)" = /in/server/splicefs-server-1.2.3.pkg ] && [ "$(package_file)" = /pkg/server/splicefs-server-1.2.3.pkg ]'

mkdir -p "$work/pkgdir/server"
: >"$work/pkgdir/server/splicefs-server-1.2.3.pkg"
runs "a package file is installed with pkg add, which resolves what it needs from the system's repository" \
    "pkg add $work/pkgdir/server/splicefs-server-1.2.3.pkg" 0 \
    "PACKAGE_FILES=$work/pkgdir; install_package system"
said "what pkg add says about a new package is shown" "Installing $work/pkgdir/server/splicefs-server-1.2.3.pkg"
runs "an install of a file that is not there says to build the packages first" "" 1 \
    "PACKAGE_FILES=$work/nowhere; install_package system"
runs "a file that pkg add refuses fails the install" \
    "pkg add $work/pkgdir/server/splicefs-server-1.2.3.pkg" 1 \
    "PACKAGE_FILES=$work/pkgdir; FAIL_TOOL=pkg install_package system"
runs "a published file is installed with pkg add too: pkg fetch proved it" "pkg add /x/published.pkg" 0 \
    "install_published_package system /x/published.pkg"
said "what pkg add says about the published package is shown" "Installing /x/published.pkg"
runs "the plain removal is pkg delete" "pkg delete -y splicefs-server" 0 "remove_package system"

: >"$work/installed"
runs "the package is installed when pkg info -e says so" "pkg info -e splicefs-server" 0 "package_installed system"
rm "$work/installed"
runs "the package is not installed when pkg info -e says not" "pkg info -e splicefs-server" 1 "package_installed system"
# shellcheck disable=SC2016
runs "the file that uninstalls is the one for pkg" "" 0 '[ "$(uninstall_file system)" = steps/uninstall-pkg.sh ]'

runs "the service is enabled with sysrc, as the install message says" "sysrc splicefsd_enable=YES" 0 "service_enable system"
runs "the service is started with service" "service splicefsd start" 0 "service_start system"
runs "enable and start are the two commands of the install message, in its order" \
    "sysrc splicefsd_enable=YES
service splicefsd start" 0 "service_start_enable system"
runs "the service is disabled by setting NO, which sysrc -x of the removal then deletes" "sysrc splicefsd_enable=NO" 0 \
    "service_disable system"
runs "the service is stopped, enabled or not" "service splicefsd onestop" 0 "service_stop system"
runs "the service is restarted" "service splicefsd restart" 0 "service_restart system"
runs "active is asked of a service that is not enabled too" "service splicefsd onestatus" 0 "service_active system"
runs "enabled is asked with service enabled" "service splicefsd enabled" 0 "service_enabled system"
# shellcheck disable=SC2016
runs "the service definition is the rc script of the package" "" 0 \
    '[ "$(service_file)" = /usr/local/etc/rc.d/splicefsd ]'

# The user is the owner of the process whose id the service writes.
# shellcheck disable=SC2016
runs "the user of the service is the owner of its process, found by the pid file of the service" \
    "ps -o user= -p 4242" 0 '[ "$(service_user system)" = splicefs ]'

# The published file is fetched by pkg from the repository that the setup script writes, which is then
# taken away again: the system is as it was apart from the file.
mkdir -p "$work/etc/pkg"
runs "the published package is fetched from the repository of the program, which is set up and taken away again" \
    "pkg fetch -y -r splicefs-server -o $work/own/published/server splicefs-server" 0 \
    "export PKG_CONFIG_DIR=$work/etc/pkg; published_file=\$(fetch_published_package system) && [ \"\$published_file\" = $work/own/published/server/All/splicefs-server-1.2.2.pkg ] && [ ! -e $work/etc/pkg/repos ] && [ ! -e $work/etc/pkg/keys ]"
runs "a fetch that fails takes the repository away and fails" \
    "pkg fetch -y -r splicefs-server -o $work/own/published/server splicefs-server" 1 \
    "export PKG_CONFIG_DIR=$work/etc/pkg; FAIL_TOOL=pkg fetch_published_package system; status=\$?; [ ! -e $work/etc/pkg/repos ] && exit \$status"

# The repository file is the setup script's own: what people get and what the test fetches from must be
# the same text, for the public site, as the built script writes it. The adapter's function that takes
# the text out of a setup script is run on the built one, and the file the stand-in pkg saw must be
# that text, which also holds the address and the key as the repository file of pkg wants them.
[ -f dist/site/setup.sh ] || { echo "run make site first" >&2; exit 1; }
runs "the repository file text of the built setup script is made, for the site of the test and the key of the machine" "" 0 \
    "setup_repo_file_text dist/site/setup.sh https://packages.example.org $work/etc/pkg/keys/splicefs.rsa.pub >$work/want.conf"
rm -f "$work/calls.repo"
runs "the repository file the machine fetches from is made for the program" \
    "pkg fetch -y -r splicefs-server -o $work/own/published/server splicefs-server" 0 \
    "export PKG_CONFIG_DIR=$work/etc/pkg; fetch_published_package system >/dev/null"
if cmp -s "$work/want.conf" "$work/calls.repo"; then
    echo "ok   the repository file is the text of the built setup script"
else
    diff "$work/want.conf" "$work/calls.repo" || true
    echo "FAIL the repository file differs from the one the built setup script writes"
    failed=$((failed + 1))
fi
# Not only equal to what the same function makes of the built script: the stanza of each program is
# there, with the address of the site and the key of the machine, and pkg's own variable left alone.
# The text is what the file must hold, a dollar sign of pkg's among it.
# shellcheck disable=SC2016
for wanted in 'splicefs-server: {' 'splicefs-client: {' 'url: "https://packages.example.org/server/freebsd/${ABI}",' \
    'url: "https://packages.example.org/client/freebsd/${ABI}",' "pubkey: \"$work/etc/pkg/keys/splicefs.rsa.pub\","; do
    if grep -qF "$wanted" "$work/calls.repo"; then
        echo "ok   the repository file holds $wanted"
    else
        echo "FAIL the repository file lacks $wanted"
        failed=$((failed + 1))
    fi
done

# With no text of the setup script to take it from, nothing is fetched and nothing is left behind.
mkdir -p "$work/no-setup"
ln -s "$root/scripts" "$work/no-setup/scripts"
ln -s "$root/keys" "$work/no-setup/keys"
echo "main" >"$work/no-setup/setup.sh.in"
runs "a setup script without the repository file fails the fetch before pkg is asked, and takes the files away" "" 1 \
    "export PKG_CONFIG_DIR=$work/etc/pkg; cd $work/no-setup; fetch_published_package system; status=\$?; [ ! -e $work/etc/pkg/repos ] && [ ! -e $work/etc/pkg/keys ] && exit \$status"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "service test pkg: all cases as expected"
