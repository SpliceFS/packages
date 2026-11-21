# shellcheck shell=sh
# Sourced inside a system a package is installed in (scripts/package-test.sh, through docker exec). It is the
# one place that says how the new package is put over the installed one.
#
# A change to the packaging alone is tested with the programs of the latest release, which is
# published already, so the new package has the version of the installed one. The package managers
# then see no upgrade (rpm refuses it, and the others do nothing or do it without a word), and the
# upgrade scripts of the package would never run. So the package is reinstalled with the package
# manager's own command, which runs them. A package of a higher version is upgraded the normal way.
# Every command here is the system's package manager, so that all of them follow its settings.

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
        # Every install goes through the package manager of the system, never through rpm or dpkg
        # itself, which ignore its settings (a system that leaves out the documentation gets it
        # from rpm -U). dnf and zypper are told to reinstall a file of the installed version. apk
        # does nothing for a file, so a file is put in a repository first; a package of a
        # repository is fixed.
        rpm:file)
            if command -v dnf >/dev/null 2>&1; then
                dnf reinstall -y -q --nogpgcheck "$3" >/dev/null
            else
                zypper --non-interactive --quiet install --force --allow-unsigned-rpm "$3" >/dev/null
            fi
            ;;
        rpm:repo)
            if command -v dnf >/dev/null 2>&1; then
                dnf reinstall -y -q "$3" >/dev/null
            else
                zypper --non-interactive install --force "$3" >/dev/null
            fi
            ;;
        apk:file) reinstall_apk_file "$3" ;;
        *) apk fix -q --reinstall "$3" >/dev/null ;;
    esac
}

# apk reinstalls only a package that a repository offers, and does nothing for a file of the
# installed version. So the file goes in a repository of its own, a folder for the CPU type with
# the file and its index, and the package, whose name is in the file, is fixed from there. Only
# that repository is read, so the run needs no network.
reinstall_apk_file() {
    ra_name="$(tar -xzOf "$1" .PKGINFO | sed -n 's/^pkgname = //p')"
    ra_repo="$(mktemp -d)"
    ra_dir="$ra_repo/$(apk --print-arch)"
    ra_status=0
    mkdir "$ra_dir" && cp "$1" "$ra_dir/" || ra_status=1
    # The index says the file needs /bin/sh, which no repository of this folder provides.
    [ "$ra_status" -ne 0 ] || apk index -q --allow-untrusted -o "$ra_dir/APKINDEX.tar.gz" "$ra_dir"/*.apk 2>/dev/null || ra_status=1
    [ "$ra_status" -ne 0 ] || apk fix -q --reinstall --allow-untrusted --no-network --repositories-file /dev/null \
        -X "$ra_repo" "$ra_name" >/dev/null || ra_status=1
    rm -rf "$ra_repo"
    return "$ra_status"
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
