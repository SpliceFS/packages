#!/bin/sh
# check-not-run: needs Docker (make package-order-test)
# Checks that the versions package-lib.sh makes sort the way a release process needs in each
# package manager: dpkg in Debian, rpm in Rocky Linux, apk in Alpine, each in its own
# container. Runs on the host (make package-order-test; CI runs it once for a change, as a job of
# ci.yml, because no package or program changes the answer). Every version in the list below must
# compare as older than the next one, and apk must accept every Alpine version as valid. A
# version is a version of the program and a revision of the package, so the list shows that a
# revision sorts above the release itself and below the next release. FreeBSD's pkg version -t is
# not here: it runs on FreeBSD only, where scripts/freebsd-lib-test.sh and the FreeBSD machine are
# the place for it.
# The container is the first system of its format in packaging/test-systems, as in the upgrade
# test. It is not booted, because the package manager alone answers the question.
# Environment: PACKAGE_DATE as for the build. The versions do not depend on the program, but
# package-lib.sh needs one to read, so PROGRAM is the first program of programs/ unless it is set.
# Inside a container the script is called as: package-order-test.sh inside FORMAT VERSION...
set -eu

# rpm compares the version first and, when they are equal, the release, each with its own
# algorithm. Both arguments are VERSION-RELEASE; a version holds no hyphen. Prints < when $1 is
# older, else what rpm answered.
rpm_compare() {
    r="$(rpm --eval "%{lua:print(rpm.vercmp('${1%%-*}', '${2%%-*}'))}")"
    if [ "$r" = 0 ]; then r="$(rpm --eval "%{lua:print(rpm.vercmp('${1#*-}', '${2#*-}'))}")"; fi
    if [ "$r" = -1 ]; then r='<'; fi
    printf '%s' "$r"
}

if [ "${1:-}" = inside ]; then
    format="$2"
    shift 2
    prev=""
    status=0
    for v in "$@"; do
        # apk version -c prints a version it cannot parse and exits 1; a valid one prints nothing.
        if [ "$format" = apk ] && ! apk version -c "$v" >/dev/null; then
            echo "FAIL apk does not accept $v"
            status=1
        fi
        if [ -n "$prev" ]; then
            case "$format" in
                deb)
                    if dpkg --compare-versions "$prev" lt "$v"; then r='<'; else r=other; fi ;;
                rpm)
                    r="$(rpm_compare "$prev" "$v")" ;;
                apk)
                    r="$(apk version -t "$prev" "$v")" ;;
                *)
                    echo "FAIL unknown format $format" >&2
                    exit 1 ;;
            esac
            if [ "$r" = '<' ]; then
                echo "ok   $format $prev < $v"
            else
                echo "FAIL $format $prev is not older than $v (result $r)"
                status=1
            fi
        fi
        prev="$v"
    done
    exit "$status"
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export PACKAGE_DATE="${PACKAGE_DATE:-20261112}"
if [ -z "${PROGRAM:-}" ]; then
    first="$(find programs -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
    PROGRAM="$(basename "$first")"
fi
export PROGRAM

# Ascending order of what the release process produces, each as VERSION:REVISION. Each
# pre-release is older than its release, each revision is newer than the one before it and older
# than the next version of the program, and a build with uncommitted changes is newer than the
# version it started from.
versions="v0.9.0:0 v1.2.3-alpha:0 v1.2.3-beta.2:0 v1.2.3-rc.1:0 v1.2.3-rc.1:1
v1.2.3-rc.1-dirty:0 v1.2.3-rc.2:0 v1.2.3:0 v1.2.3:1 v1.2.3:2 v1.2.3:10 v1.2.3-dirty:0
v1.2.4-rc.1:0 v1.2.4:0 v1.2.4:1"

failed=0
for format in deb rpm apk; do
    image="$(awk -v f="$format" '$1 == f { print $2; exit }' packaging/test-systems)"
    [ -n "$image" ] || { echo "FAIL packaging/test-systems has no $format system" >&2; exit 1; }
    list=""
    for v in $versions; do
        # What the format's tool is given is the whole version of a package: the revision is
        # part of it for deb, the release for rpm, and -r for Alpine.
        got="$(VERSION="${v%:*}" REVISION="${v#*:}" FORMAT="$format" sh -c '
            . scripts/package-lib.sh
            case "$FORMAT" in
                deb) echo "$debver" ;;
                rpm) echo "$rpmver-$rpmrel" ;;
                *) echo "$apkver-r$apkrel" ;;
            esac')"
        list="$list $got"
    done
    # $list is split on purpose: one argument per version, none contains a space.
    # shellcheck disable=SC2086
    docker run --rm -v "$root":/src:ro "$image" sh /src/scripts/package-order-test.sh \
        inside "$format" $list || failed=$((failed + 1))
done
[ "$failed" -eq 0 ] || { echo "ordering failed for $failed format(s)"; exit 1; }
echo "package version ordering: ok in deb, rpm and apk"
