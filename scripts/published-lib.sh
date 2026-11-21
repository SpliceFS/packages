# shellcheck shell=sh
# What the scripts that read the package site have in common (scripts/published-newest.sh,
# scripts/package-test.sh): where the site is, what the published files are called and where
# they are, and how they are downloaded and proven. What people have installed is what the site serves, so
# nothing here asks GitHub. Sourced after scripts/package-lib.sh (or scripts/program-conf.sh for the
# scripts that only read the index), which says what the program and its versions are called. The
# downloads are those of scripts/fetch-lib.sh, which insists on HTTPS. name, deb_arch, rpm_arch,
# apk_arch and PACKAGE_DATE are set by the files this one is sourced after.
# The words use_published_version sets are read by the scripts that source this file.
# shellcheck disable=SC2154,SC2034

# shellcheck source=fetch-lib.sh
. scripts/fetch-lib.sh

# The address of the package site, PACKAGE_SITE (https://packages.splicefs.org), and of the folder of
# the program PROGRAM on it.
site_root="${PACKAGE_SITE:-https://packages.splicefs.org}"
site_url="$site_root/$PROGRAM"

# What scripts/published-newest.sh prints, and the version record keeps (UPGRADE_FROM), when the
# site was read and lists no package of the program. A record that is empty says the site was not
# read: the tests then ask it themselves. This word says it was, so no later job asks again.
nothing_published=none

# Writes the apt index of the program, which lists every version ever published, into the file
# $1. INDEX_FILE is a test hook that names a local index file and replaces the download. A failed
# download must never read as "nothing is published": the upgrade test would then be skipped.
fetch_apt_index() {
    if [ -n "${INDEX_FILE:-}" ]; then
        cp "$INDEX_FILE" "$1" 2>/dev/null || fail "could not read the index $INDEX_FILE"
    else
        apt_index_url="$site_url/apt/dists/stable/main/binary-amd64/Packages"
        fetch_site_file "$apt_index_url" "$1" || fail "could not read $apt_index_url"
    fi
}

# Prints the versions of the package of the program that the apt index in the file $1 lists, one
# for each stanza, as the index writes them: 1.2.3. A version is the same in every format
# (scripts/package-lib.sh), so one format is enough to read the published versions from.
published_debvers() {
    awk -v name="$name" '
        $1 == "Package:" { package = $2 }
        $1 == "Version:" && package == name { print $2 }
    ' "$1"
}

# Prints the newest of the deb versions on the standard input, or nothing when there is none. The
# order is the one the package managers use: the parts of the version as numbers, a pre-release
# (1.2.3~rc.1) before its release and after the version before it. A line that is not a version
# of ours is not counted, as package_release_of_debver refuses it: that includes a name with a
# revision (1.2.3-1), which this repository does not publish.
newest_debver() {
    LC_ALL=C awk '
        {
            version = $0
            if (version ~ /-[0-9]+$/) next
            pre = ""
            if (index(version, "~") > 0) {
                pre = substr(version, index(version, "~") + 1)
                version = substr(version, 1, index(version, "~") - 1)
            }
            if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) next
            split(version, part, ".")
            # A release sorts above every pre-release of it.
            rank = 9
            number = 0
            if (pre != "") {
                if (pre !~ /^(alpha|beta|pre|rc)\.?[0-9]*$/) next
                word = pre
                sub(/[.0-9]+$/, "", word)
                number = pre
                sub(/^[a-z]+\.?/, "", number)
                rank = (word == "alpha") ? 1 : (word == "beta") ? 2 : (word == "pre") ? 3 : 4
            }
            # Digits of one width, so that a comparison of the text is a comparison of the numbers.
            key = sprintf("%09d%09d%09d%d%09d", part[1], part[2], part[3], rank, number)
            if (best == "" || key > best) {
                best = key
                newest = $0
            }
        }
        END { if (newest != "") print newest }
    '
}

# Prints the published version the upgrade starts from: the one the build recorded
# (UPGRADE_FROM, which use_recorded_version sets), so that a package published after the build,
# which is newer than the packages, never turns the upgrade into a downgrade. A build that
# recorded none (a build by hand) starts from the newest package on the site, as
# scripts/published-newest.sh reads it. Prints nothing when nothing is published, whether the
# build or this call read that. A package of the program that is being published is never it: only
# what the site serves counts. Status 1 when the site could not be read.
upgrade_from_version() {
    uf_version="${UPGRADE_FROM:-}"
    if [ -z "$uf_version" ]; then
        uf_version="$(sh scripts/published-newest.sh "$PROGRAM")" || return 1
    fi
    [ "$uf_version" = "$nothing_published" ] || printf '%s\n' "$uf_version"
}

# Sets old_tag (the program version of the published package whose deb version is $1), and
# old_debver, old_rpmver, old_rpmrel, old_apkver and old_apkrel, what package_versions makes of
# it. Ends the caller with a message for a version that is not one of ours: call it as a simple
# command.
use_published_version() {
    old_tag="$(package_release_of_debver "$1")" || exit 1
    up_names="$(package_versions "$old_tag" "$PACKAGE_DATE")" || exit 1
    read -r old_debver old_rpmver old_rpmrel old_apkver old_apkrel _ <<LIST
$up_names
LIST
}

# Sets deb_arch, rpm_arch and apk_arch, the CPU type in the spelling of each format, for the
# platform $1 (linux/amd64 or linux/arm64). Ends the caller with a message for another platform:
# call it as a simple command.
package_arches() {
    case "$1" in
        linux/amd64) deb_arch=amd64; rpm_arch=x86_64; apk_arch=x86_64 ;;
        linux/arm64) deb_arch=arm64; rpm_arch=aarch64; apk_arch=aarch64 ;;
        # The FreeBSD package is named by its ABI, not by one of these words, and no published file
        # of it is looked for by them.
        freebsd/amd64) ;;
        *) fail "no package CPU type for $1" ;;
    esac
}

# Prints the path on the site, from the folder of the program, of the published file of the format
# $1 for the words of use_published_version: $2 (deb), $3 and $4 (rpm, and its release), $5 and $6
# (apk, and its release), for the CPU types deb_arch, rpm_arch and apk_arch of the caller. An
# Alpine package file name carries no CPU type: the folder of the CPU type does.
published_path() {
    case "$1" in
        deb) echo "apt/pool/main/${name%"${name#?}"}/$name/${name}_${2}_$deb_arch.deb" ;;
        rpm) echo "rpm/$rpm_arch/$name-$3-$4.$rpm_arch.rpm" ;;
        *) echo "alpine/$apk_arch/$name-$5-r$6.apk" ;;
    esac
}

# Downloads the file at the path $1 of the site (published_path) into the folder $2 unless it is
# there, and proves it (scripts/published-verify.sh), also when it was there: a file that does not
# prove is removed. Status 1 when the download failed or the file does not prove, with the reason
# on the standard error.
download_published_file() {
    mkdir -p "$2"
    dl_file="$2/$(basename "$1")"
    [ -f "$dl_file" ] || fetch_site_file "$site_url/$1" "$dl_file" || return 1
    PROGRAM="$PROGRAM" sh scripts/published-verify.sh "$1" "$dl_file" || {
        rm -f "$dl_file"
        return 1
    }
}

# Downloads the public signing keys of the site into the folder $1 and proves that they are the keys of
# this repository (keys/), the ones scripts/published-verify.sh proves the signed index with: a
# package manager that trusts the key from the site then trusts the key that proves the index. The
# files are the OpenPGP key (splicefs.asc: apt, dnf, zypper) and the RSA key (splicefs.rsa.pub: apk).
# A key that does not prove is removed. Status 1 when a download failed or a key does not prove, with
# the reason on the standard error.
download_published_keys() {
    mkdir -p "$1"
    for dk_name in splicefs.asc splicefs.rsa.pub; do
        fetch_site_file "$site_root/keys/$dk_name" "$1/$dk_name" || return 1
        cmp -s "keys/$dk_name" "$1/$dk_name" || {
            echo "$site_root/keys/$dk_name is not keys/$dk_name of this repository" >&2
            rm -f "$1/$dk_name"
            return 1
        }
    done
}
