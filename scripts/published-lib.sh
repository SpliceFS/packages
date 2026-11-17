# shellcheck shell=sh
# What the tests that start from the published release have in common (scripts/upgrade-test.sh,
# scripts/lifecycle-repo.sh): which release is the newest, what its files are called and how they
# are downloaded. Sourced after scripts/package-lib.sh, which says what the version is called
# in each package format. The downloads insist on HTTPS, also after a redirect, so that a
# redirect can never hand over a package from a plain address. name, deb_arch, rpm_arch,
# apk_arch and PACKAGE_DATE are set by the files this one is sourced after.
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

# Prints the version of the tag $1 in the three package formats, "<deb> <rpm> <apk>", the way
# package-lib.sh makes them. It runs in a shell of its own because package-lib.sh reads VERSION.
release_versions() {
    VERSION="$1" PACKAGE_DATE="$PACKAGE_DATE" sh -c \
        '. scripts/package-lib.sh; echo "$debver $rpmver $apkver"'
}

# Prints the name of the published file of the format $1 for the versions $2 (deb), $3 (rpm) and
# $4 (apk), for the CPU types deb_arch, rpm_arch and apk_arch of the caller. The release
# holds the Alpine package under a name with the CPU type, which is not the name in dist.
release_file_name() {
    case "$1" in
        deb) echo "${name}_${2}_$deb_arch.deb" ;;
        rpm) echo "$name-$3-1.$rpm_arch.rpm" ;;
        *) echo "$name-$4-r0.$apk_arch.apk" ;;
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
