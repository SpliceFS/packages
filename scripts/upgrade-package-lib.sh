# shellcheck shell=sh
# Sourced inside a system a package is installed in (scripts/upgrade-test-deb.sh, -rpm.sh and
# -apk.sh, and scripts/lifecycle-test-deb.sh, -rpm.sh and -apk.sh through docker exec). It is the
# one place that says how the new package is put over the installed one.
#
# A change to the packaging alone is published with no new version, so the new package can have
# the version of the installed one. The package managers then see no upgrade (rpm refuses it, and
# the others do nothing or do it without a word), and the upgrade scripts of the package would
# never run. So the package is reinstalled with the package manager's own command, which runs
# them. A package of a higher version is upgraded the normal way.

# Installs the new package over the installed one, with the package manager of the system.
# Usage: upgrade_package FORMAT OLD NEW SOURCE TARGET
#   OLD, NEW  the program version of the installed package and of the new one, as v1.2.3
#   SOURCE    file when TARGET is a package file, repo when it is a package name of a repository
upgrade_package() {
    if [ "$2" = "$3" ]; then
        reinstall_package "$1" "$4" "$5"
    else
        upgrade_package_to_newer "$1" "$4" "$5"
    fi
}

reinstall_package() {
    case "$1:$2" in
        deb:*) apt-get install -y -qq --reinstall "$3" >/dev/null ;;
        # rpm replaces a file itself, because dnf and zypper see nothing to do for it. Neither
        # does apk for a file, which it adds again; a package of a repository is fixed.
        rpm:file) rpm -U --replacepkgs --nosignature "$3" >/dev/null ;;
        rpm:repo)
            if command -v dnf >/dev/null 2>&1; then
                dnf reinstall -y -q "$3" >/dev/null
            else
                zypper --non-interactive install --force "$3" >/dev/null
            fi
            ;;
        apk:file) apk add -q --allow-untrusted "$3" >/dev/null ;;
        *) apk fix -q --reinstall "$3" >/dev/null ;;
    esac
}

# The keys of a package file are not imported: the old one is signed with the release key and
# the new one with a test key, and the signatures are the repository tests' subject, not this
# one's. A package of a repository is checked as a person's system checks it.
upgrade_package_to_newer() {
    case "$1:$2" in
        deb:file) apt-get install -y -qq "$3" >/dev/null ;;
        deb:repo) apt-get install -y -qq --only-upgrade "$3" >/dev/null ;;
        rpm:file)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y -q --nogpgcheck "$3" >/dev/null
            else
                zypper --non-interactive --quiet install --allow-unsigned-rpm "$3" >/dev/null
            fi
            ;;
        rpm:repo)
            if command -v dnf >/dev/null 2>&1; then
                dnf upgrade -y -q "$3" >/dev/null
            else
                zypper --non-interactive update "$3" >/dev/null
            fi
            ;;
        apk:file) apk add -q --allow-untrusted "$3" >/dev/null ;;
        *) apk add -q -u "$3" >/dev/null ;;
    esac
}
