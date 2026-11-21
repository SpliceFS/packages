# shellcheck shell=sh
# The scripts that source this file read these variables; this file reads none of them.
# shellcheck disable=SC2034
# Sourced by the package scripts, from the root of the repository. Says what is being packaged
# and what its version is called in each package format.
# shellcheck source=program-conf.sh
. scripts/program-conf.sh
: "${VERSION:?VERSION is not set}"
: "${PACKAGE_DATE:?PACKAGE_DATE is not set}"

# What program.conf sets is unknown to ShellCheck, which cannot follow it.
# shellcheck disable=SC2154
confdir="/etc/splicefs/${name#splicefs-}"
# One folder name per line; see the file for why the package ships them empty.
confsubdirs="$(grep -v -e '^#' -e '^$' "$defs/config-folders")"

# Prints the links the program installs, "<link> <target>" a line. They are named in the links
# file of the program, and a program without the file has none. The links are made and the
# package tests check them from this list, so that the file is the one place that says them.
package_link_list() {
    [ -f "$defs/links" ] || return 0
    grep -v -e '^#' -e '^$' "$defs/links"
}

# Prints the links of the FreeBSD package, "<link> <target>" a line: the same links, moved from /usr
# to /usr/local, where that package installs. The links file stays the one place that says which
# links there are.
package_freebsd_link_list() {
    package_link_list | sed -e 's|^/usr/|/usr/local/|' -e 's| /usr/| /usr/local/|'
}

# Makes the links the program installs under the folder $1, for the package formats that build a
# tree of files.
package_links() {
    package_link_list | while read -r link target; do
        install -d "$1$(dirname "$link")"
        ln -s "$target" "$1$link"
    done
}

# Prints the name of a new folder that holds the links of the program and nothing else, for the
# formats whose definition copies a tree over the root of the package. The folder is readable by
# everyone because the copy gives its mode to the root of the package.
package_link_tree() {
    linktree="$(mktemp -d)"
    chmod 755 "$linktree"
    package_links "$linktree"
    echo "$linktree"
}

# Prints the documents of the package as paths in the source tree SRC, separated by spaces. They
# are named in program.conf and are not kept in this repository, because they change with every
# version of the program.
package_docs() {
    [ -n "${SRC:-}" ] || fail "SRC is not set: it is the source tree of the program at this version"
    list=""
    # The names are ours and hold no spaces, so the list is split on purpose. docs is set by
    # program.conf.
    # shellcheck disable=SC2154
    for doc in $docs; do list="$list${list:+ }$SRC/$doc"; done
    echo "$list"
}

# Prints the packing list that pkg create reads for the FreeBSD package, paths relative to
# /usr/local. Every line is made from a fact that program.conf, links and config-folders hold: the
# programs, the links, the rc script that is named after the service program, and the
# configuration folders.
# A folder comes before the one that holds it, so that pkg removes the inner one first. The
# folder of all SpliceFS programs is shared by the server and the client, and pkg removes it
# only when it is empty.
# What program.conf sets is unknown to ShellCheck, which cannot follow it.
# shellcheck disable=SC2154
package_freebsd_plist() {
    for plist_program in $programs; do echo "bin/$plist_program"; done
    package_freebsd_link_list | while read -r plist_link _; do echo "${plist_link#/usr/local/}"; done
    echo "etc/rc.d/$program"
    for plist_folder in $confsubdirs; do echo "@dir ${confdir#/}/$plist_folder"; done
    echo "@dir ${confdir#/}"
    echo "@dir $(dirname "${confdir#/}")"
}

# Writes the service unit as the packages ship it to the file $1. The unit in the repository
# is written for a manual install under /usr/local; the packages put the program in /usr/bin.
package_unit() {
    # shellcheck disable=SC2154
    sed 's|/usr/local/bin/|/usr/bin/|' "$defs/systemd/$program.service" > "$1"
}

# Prints the file $2 (an install script of the program, or its rpm spec) with the service steps
# filled in. A line that holds only @service:STEP@ is replaced by the file
# packaging/service/MANAGER/STEP, indented like the line, where $1 is the service manager
# (systemd or openrc) and @SERVICE@ is the name of the service. The steps are the one place that
# says what installing, upgrading and removing do to the service, for every program and every
# package format; what only one program needs stays in its own file.
# What program.conf sets is unknown to ShellCheck, which cannot follow it.
# shellcheck disable=SC2154
package_script() {
    while IFS= read -r script_line; do
        script_text="${script_line#"${script_line%%[![:space:]]*}"}"
        case "$script_text" in
            @service:*@)
                script_step="packaging/service/$1/${script_text#@service:}"
                script_step="${script_step%@}"
                [ -f "$script_step" ] || fail "$script_step does not exist"
                sed -e "s|@SERVICE@|$program|g" -e "s|^\(.\)|${script_line%"$script_text"}\1|" "$script_step"
                ;;
            *) printf '%s\n' "$script_line" ;;
        esac
    done < "$2"
}

# Fetches an image for one test system: up to 3 tries, 5 seconds apart, quiet on success.
# A registry that fails to deliver now and then is not a fault of the package under test, so
# the callers report a failed download as one. Pulling first also keeps the download out of
# the log of the test itself. Usage: pull_image PLATFORM IMAGE; status 1 after the last try.
pull_image() {
    tries=0
    while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        if docker pull --quiet --platform "$1" "$2" >/dev/null 2>&1; then return 0; fi
        if [ "$tries" -lt 3 ]; then sleep 5; fi
    done
    return 1
}

# Runs the command once a second until it succeeds or the given number of seconds is over.
wait_for() {
    limit="$1"
    shift
    waited=0
    until "$@"; do
        waited=$((waited + 1))
        [ "$waited" -lt "$limit" ] || return 1
        sleep 1
    done
}

# Ends this system's run with the message when the command fails. The command runs through
# "$@" because errexit is off in every check (see run_checks): each one is guarded
# explicitly, and its status is the answer.
must() {
    message="$1"
    shift
    "$@" || fail "$message"
}

# The same for a command that has to fail: ends the run with the message when it succeeds.
refuse() {
    message="$1"
    shift
    if "$@"; then fail "$message"; fi
}

# Whether a line of packaging/test-systems is part of this run. ONLY names one format or one
# image; empty means every line. Every script that walks the list asks here, so that CI can
# run one format per job the same way each of them. Usage: system_selected FORMAT IMAGE.
system_selected() {
    [ -z "${ONLY:-}" ] || [ "$ONLY" = "$1" ] || [ "$ONLY" = "$2" ]
}

# Starts a server image as a container the way the images README boots one: the service
# manager is process 1. The image sets the rest (the container variable and the stop signal).
# The Alpine images need none of these options and are not harmed by them, so every system
# is started the same way. The arguments are the rest of the docker run command: name,
# platform, mounts, and the image last. Prints nothing on success.
boot_system() {
    docker run -d --privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock --tmpfs /tmp "$@" >/dev/null
}

# Status 0 when the service manager of the container $2 has finished booting. For systemd that
# is what is-system-running says; units that cannot work in a container make its state
# degraded, which is fine. OpenRC (the apk format) is up once it reaches the default
# runlevel, where the package adds the service. Usage: service_manager_up FORMAT CONTAINER.
service_manager_up() {
    case "$1" in
        apk)
            level="$(docker exec "$2" rc-status --runlevel 2>/dev/null)" || true
            [ "$level" = default ]
            ;;
        *)
            state="$(docker exec "$2" systemctl is-system-running 2>/dev/null)" || true
            # Any other state means systemd is not up yet.
            case "$state" in running | degraded) return 0 ;; *) return 1 ;; esac
            ;;
    esac
}

# Returns once the service manager of the container $2 has booted, so that a test never starts
# on a system that is still coming up. It polls because the first commands cannot run until
# the manager is process 1, and every wait has a limit: it ends with status 1 when the
# container stops or when the manager is not up after 90 seconds.
# Usage: wait_booted FORMAT CONTAINER.
wait_booted() {
    waited=0
    # service_manager_up is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    until service_manager_up "$1" "$2"; do
        # A container that cannot be inspected is counted as stopped.
        running="$(docker inspect -f '{{.State.Running}}' "$2")" || running=""
        if [ "$running" != true ]; then
            echo "the container stopped before its service manager was up:" >&2
            docker logs --tail 30 "$2" >&2 || true
            return 1
        fi
        waited=$((waited + 1))
        if [ "$waited" -ge 90 ]; then
            echo "the service manager is not up after 90 seconds" >&2
            return 1
        fi
        sleep 1
    done
}

# Prints the version of a package in every format, from the version of the program ($1) and the
# date of the build ($2), as one line of six words:
#   deb version, rpm version, rpm release, Alpine version, Alpine release, FreeBSD version
# It is the one place that says how a version is written in each format, and every package script
# and every test reads the result from here.
#
# $1 is the version in the file VERSION as the Makefile makes it: v1.2.3 for a release,
# v1.2.3-rc.1 for a pre-release, and a trailing -dirty when the tree has uncommitted changes.
# It is split into core (1.2.3), pre (rc.1, may be empty) and extra (dirty, or empty), which is
# what makes a build something other than the released version. Anything else is refused: a
# version that is not in this form would be packaged under a number that sorts wrongly.
#
# A package is published only for a new release of its program, so the version of the program is
# the whole version: the deb and FreeBSD versions carry nothing after it, the rpm release is 1
# (a release starts at 1) and the Alpine release is 0, as in every package published so far.
package_versions() {
    pv_release="${1%-dirty}"
    pv_extra=""
    if [ "$pv_release" != "$1" ]; then pv_extra=dirty; fi
    printf '%s' "$pv_release" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-.+)?$' ||
        fail "version $1 is not vMAJOR.MINOR.PATCH[-pre-release]"
    pv_core="${pv_release#v}"
    pv_core="${pv_core%%-*}"
    pv_pre=""
    if [ "$pv_core" != "${pv_release#v}" ]; then pv_pre="${pv_release#v"$pv_core"-}"; fi
    # Alpine takes only these pre-release words, so nothing else can be published.
    if [ -n "$pv_pre" ]; then
        printf '%s' "$pv_pre" | grep -Eq '^(alpha|beta|pre|rc)(\.?[0-9]+)?$' ||
            fail "version $1: pre-release $pv_pre must be alpha, beta, pre or rc, then a number"
    fi

    # Debian and rpm: a tilde sorts before everything, so 1.2.3~rc.1 is older than 1.2.3, and
    # a plus suffix sorts after, so 1.2.3+dirty is newer than the release it follows.
    pv_deb="$pv_core"
    if [ -n "$pv_pre" ]; then pv_deb="$pv_deb~$pv_pre"; fi
    if [ -n "$pv_extra" ]; then pv_deb="$pv_deb+$pv_extra"; fi
    pv_rpm="$pv_deb"

    # An Alpine version allows digits and a fixed list of suffixes only, so the pre-release
    # becomes _rc1 and a build that is not exactly the release carries the date of its
    # commit: 1.2.3_rc1_git20261112.
    pv_apk="$pv_core"
    if [ -n "$pv_pre" ]; then pv_apk="${pv_apk}_$(printf '%s' "$pv_pre" | tr -d .)"; fi
    if [ -n "$pv_extra" ]; then pv_apk="${pv_apk}_git$2"; fi

    # FreeBSD compares versions field by field and knows rc and friends as older than the
    # release, so the pre-release becomes one more field (1.2.3.rc1) and a build that is not
    # exactly the release carries the date of its commit as the last field: 1.2.3.20261112.
    pv_pkg="$pv_core"
    if [ -n "$pv_pre" ]; then pv_pkg="$pv_pkg.$(printf '%s' "$pv_pre" | tr -d .)"; fi
    if [ -n "$pv_extra" ]; then pv_pkg="$pv_pkg.$2"; fi

    printf '%s %s 1 %s 0 %s\n' "$pv_deb" "$pv_rpm" "$pv_apk" "$pv_pkg"
}

# Prints the program version of the deb version $1 as the package site writes it, "v1.2.3" for
# 1.2.3 and "v1.2.3-rc.1" for 1.2.3~rc.1: package_versions read backwards for the deb format, so
# that what a published package is called is said here and nowhere else.
package_release_of_debver() {
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(~(alpha|beta|pre|rc)(\.?[0-9]+)?)?$' ||
        fail "$1 is not a package version this repository publishes"
    case "$1" in
        *~*) printf 'v%s-%s\n' "${1%%~*}" "${1#*~}" ;;
        *) printf 'v%s\n' "$1" ;;
    esac
}

# The words of package_versions for the program version and date of this run. The call
# is a command substitution, where fail would end only the substitution, so its status ends the
# script here.
versions="$(package_versions "$VERSION" "$PACKAGE_DATE")" || exit 1
read -r debver rpmver rpmrel apkver apkrel pkgver <<WORDS
$versions
WORDS

# The FreeBSD version of the package the upgrade check builds (scripts/freebsd-job.sh): the same
# program version with port revision 1, which pkg takes as an upgrade of the one installed. It is
# built only inside that check and is never published, so no other format has one.
package_freebsd_upgrade_version() {
    printf '%s_1\n' "$pkgver"
}
