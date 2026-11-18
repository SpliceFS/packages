# shellcheck shell=sh
# What the tests that start from the published release have in common (scripts/upgrade-test.sh,
# scripts/lifecycle-repo.sh): which release they start from, what its files are called and how
# they are downloaded. Sourced after scripts/package-lib.sh, which says what the version is called
# in each package format (package_versions). The downloads insist on HTTPS, also after a
# redirect, so that a redirect can never hand over a package from a plain address. name,
# deb_arch, rpm_arch, apk_arch and PACKAGE_DATE are set by the files this one is sourced after.
# shellcheck disable=SC2154

# Prints the tag of the newest release of the repository $1 (release_repo of program.conf), or
# nothing when it has none: GitHub answers with the releases page itself then. A network
# failure is a failure and not a reason to skip, so the status is 1 for it.
latest_release_tag() {
    final_url="$(curl -fsSIL --proto =https --proto-redir =https --retry 3 -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")" ||
        return 1
    case "$final_url" in
        */releases/tag/*) printf '%s\n' "${final_url##*/}" ;;
        *) ;;
    esac
}

# Prints the tag of the release the tests start from, for the repository $1 (release_repo of
# program.conf): the one the build recorded (UPGRADE_FROM, which use_recorded_version sets), so
# that a release made after the build, which is newer than the packages, never turns the upgrade
# into a downgrade. A build that recorded none (a build by hand) starts from the newest release,
# as latest_release_tag says. The status is 1 when that could not be asked.
upgrade_from_tag() {
    if [ -n "${UPGRADE_FROM:-}" ]; then
        printf '%s\n' "$UPGRADE_FROM"
    else
        latest_release_tag "$1"
    fi
}

# The packages attached to the release of a program are the revision 0 of that version: they
# are made when the program is released. A later revision of the same version is a change to the
# packaging alone and goes to the package repository, never to the release.
released_revision=0

# Prints the words package_versions makes of the tag $1 as it was released, "<deb> <rpm>
# <rpm release> <apk> <apk release> <pkg>". A version it refuses ends the shell it runs in, with
# its message.
release_versions() {
    package_versions "$1" "$released_revision" "$PACKAGE_DATE"
}

# Prints the name of the published file of the format $1 for the words of release_versions: $2
# (deb), $3 and $4 (rpm, and its release), $5 and $6 (apk, and its release), for the CPU types
# deb_arch, rpm_arch and apk_arch of the caller. The release holds the Alpine package under a
# name with the CPU type, which is not the name in dist.
release_file_name() {
    case "$1" in
        deb) echo "${name}_${2}_$deb_arch.deb" ;;
        rpm) echo "$name-$3-$4.$rpm_arch.rpm" ;;
        *) echo "$name-$5-r$6.$apk_arch.apk" ;;
    esac
}

# Downloads the file $3 of the release $2 of the repository $1 into the folder $4 unless it is
# there. It is written under another name first, so an interrupted download is never mistaken
# for the package. Status 1 when the download failed.
download_release_file() {
    [ ! -f "$4/$3" ] || return 0
    mkdir -p "$4"
    if ! curl -fsSL --proto =https --proto-redir =https --retry 3 -o "$4/$3.part" "https://github.com/$1/releases/download/$2/$3" ||
        ! mv "$4/$3.part" "$4/$3"; then
        rm -f "$4/$3.part"
        return 1
    fi
}
