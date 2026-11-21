# shellcheck shell=sh
# Whether the package manager of a system still holds a package, for every package format. It runs
# inside the system, so a Linux container and the FreeBSD machine ask the same function. Sourced
# after scripts/package-lib.sh, which provides fail.
#
# "Held" is not "installed": dpkg keeps the configuration of a package that was removed and not
# purged, as the state config-files (dpkg lists it as rc), and that package still has to be named to
# the documented removal, which purges it. The other package managers hold nothing of a removed
# package.
# Usage: package_held FORMAT NAME. Status 0 when the package manager holds the package.
package_held() {
    case "$1" in
        deb)
            # A package dpkg has never heard of makes dpkg -s fail; one it has forgotten has the
            # state not-installed.
            held_state="$(dpkg -s "$2" 2>/dev/null | sed -n 's/^Status: .* //p')"
            [ -n "$held_state" ] && [ "$held_state" != not-installed ]
            ;;
        rpm) rpm -q "$2" >/dev/null 2>&1 ;;
        apk) apk info -e "$2" >/dev/null 2>&1 ;;
        pkg) pkg info -e "$2" >/dev/null 2>&1 ;;
        *) fail "package_held: no package format $1" ;;
    esac
}
