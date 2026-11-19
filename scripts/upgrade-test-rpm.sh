#!/bin/sh
# The rpm part of the upgrade test (scripts/upgrade-test.sh), run inside a throwaway
# container of an rpm based system.
# Usage: upgrade-test-rpm.sh list PACKAGE          prints the listing of one package
#        upgrade-test-rpm.sh upgrade OLD NEW       installs OLD, writes markers, upgrades
#                                                  to NEW and checks the result
set -eu

# shellcheck source=upgrade-lib.sh
. scripts/upgrade-lib.sh

list_package() {
    # rpm reads the package itself, so nothing is extracted. A folder has no content sum and
    # only a link has a target; "-" stands for each of them so every line has the same fields.
    rpm -qp --qf '[%{FILEMODES:perms}|%{FILEUSERNAME}:%{FILEGROUPNAME}|%{FILEDIGESTS}|%{FILELINKTOS}|%{FILENAMES}\n]' "$1" |
        awk -F'|' '{
            kind = "file"
            if (substr($1, 1, 1) == "d") kind = "dir"
            if (substr($1, 1, 1) == "l") kind = "link"
            detail = $3
            if (kind == "link") detail = $4
            if (detail == "") detail = "-"
            print kind, $1, $2, detail, $5
        }'
    # The package's own declaration of what it needs. The rpmlib lines name what the rpm
    # program that built the package could do, not what the package needs.
    rpm -qp --qf '[%{REQUIRENAME} %{REQUIREFLAGS:deptype} %{REQUIREFLAGS:depflags} %{REQUIREVERSION}\n]' "$1" |
        grep -v '^rpmlib(' | sed 's/^/meta requires /'
    rpm -qp --qf '[%{PROVIDENAME}\n]' "$1" | sed 's/^/meta provides /'
    # The name, CPU type, license and texts. The version and release change in every build.
    rpm -qp --qf 'meta name %{NAME}\nmeta arch %{ARCH}\nmeta license %{LICENSE}\nmeta url %{URL}\nmeta summary %{SUMMARY}\n' "$1"
    # A package without such a script prints "(none)", which is the same in every version.
    for tag in PREIN POSTIN PREUN POSTUN PRETRANS POSTTRANS; do
        sum="$(rpm -qp --qf "%{$tag}" "$1" | sha256sum)"
        printf 'script %s %s\n' "$tag" "${sum%% *}"
    done
}

# Installs the old package the way a person does, with the system's package manager, which also
# fetches what the package needs (the client needs fuse3). The keys of the packages are not
# imported here: the old one is signed with the release key, the new one with a test key, and the
# signatures are the repository tests' subject, not this one's.
rpm_install() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y -q --nogpgcheck "$1" >/dev/null
    else
        zypper --non-interactive --quiet install --allow-unsigned-rpm "$1" >/dev/null
    fi
}

mode="${1:-}"
case "$mode" in
    list)
        list_package "${2:?usage: upgrade-test-rpm.sh list PACKAGE}"
        ;;
    upgrade)
        old="${2:?usage: upgrade-test-rpm.sh upgrade OLD NEW}"
        new="${3:?usage: upgrade-test-rpm.sh upgrade OLD NEW}"
        # rpm_install is one command, so its status is that command's, set -e or not.
        # shellcheck disable=SC2310
        rpm_install "$old" || fail "rpm upgrade: installing the old package failed"
        write_markers rpm
        # upgrade_package is one command, so its status is that command's, set -e or not.
        # shellcheck disable=SC2310
        upgrade_package rpm "$PUBLISHED_VERSION" "$VERSION" file "$new" || fail "rpm upgrade: upgrading to the new package failed"
        unit="/usr/lib/systemd/system/$program.service"
        # The files the new package lists must all be there after the upgrade.
        listing="$(mktemp)"
        list_package "$new" > "$listing"
        user="$(sed -n 's/^User=//p' "$unit")"
        installed="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$name")"
        verify_upgrade rpm "$user" "$listing" "$installed" "$rpmver-$rpmrel"
        ;;
    *)
        echo "usage: upgrade-test-rpm.sh list PACKAGE | upgrade OLD NEW" >&2
        exit 2
        ;;
esac
