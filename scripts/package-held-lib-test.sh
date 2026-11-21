#!/bin/sh
# check: package-held-lib.sh: whether the package manager of each format still holds a package
# Test of scripts/package-held-lib.sh. It runs inside a system a package was installed in; here
# the system is a folder of stand-ins for dpkg, rpm, apk and pkg on the PATH, each of which
# answers only to the exact command the library must ask, so the test needs no Docker (part of
# make check). The answer comes from the environment of the call.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

cat >"$work/dpkg" <<'STAND_IN'
#!/bin/sh
# dpkg -s of a package it has a record of prints the record, and fails for one it has none of.
[ "$*" = "-s splicefs-server" ] || exit 2
[ -n "${FAKE_DPKG_STATUS:-}" ] || exit 1
printf 'Package: splicefs-server\nStatus: %s\nVersion: 1.2.3\n' "$FAKE_DPKG_STATUS"
STAND_IN
for each in "rpm -q" "apk info -e" "pkg info -e"; do
    command_name="${each%% *}"
    cat >"$work/$command_name" <<STAND_IN
#!/bin/sh
# Answers with the status in FAKE_ANSWER for the one command the library must ask.
[ "\$*" = "${each#* } splicefs-server" ] || exit 2
exit "\${FAKE_ANSWER:-1}"
STAND_IN
done
chmod 755 "$work/dpkg" "$work/rpm" "$work/apk" "$work/pkg"

# $1 case name, $2 format, $3 what the package manager says (the dpkg status, or the status of the
# command), $4 whether the package is held: yes or no.
holds() {
    status=0
    # package_held is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2016
    PATH="$work:$PATH" FAKE_DPKG_STATUS="$3" FAKE_ANSWER="$3" sh -c \
        'fail() { echo "$*" >&2; exit 1; }; . scripts/package-held-lib.sh; package_held "$@"' \
        sh "$2" splicefs-server >/dev/null 2>&1 || status=$?
    got=no
    [ "$status" -ne 0 ] || got=yes
    if [ "$got" = "$4" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: wanted %s, got %s\n' "$1" "$4" "$got"
        failed=$((failed + 1))
    fi
}

holds "deb: installed is held" deb "install ok installed" yes
holds "deb: removed with its configuration left (rc) is held" deb "deinstall ok config-files" yes
holds "deb: purged is not held" deb "purge ok not-installed" no
holds "deb: never installed is not held" deb "" no
holds "rpm: rpm -q finds it" rpm 0 yes
holds "rpm: rpm -q does not find it" rpm 1 no
holds "apk: apk info -e finds it" apk 0 yes
holds "apk: apk info -e does not find it" apk 1 no
holds "freebsd: pkg info -e finds it" freebsd 0 yes
holds "freebsd: pkg info -e does not find it" freebsd 1 no

# A format nobody wrote a case for is an error that names it, so it is never read as "not held".
# shellcheck disable=SC2016
said="$(PATH="$work:$PATH" sh -c 'fail() { echo "$*" >&2; exit 1; }; . scripts/package-held-lib.sh; package_held "$@"' \
    sh nonsense splicefs-server 2>&1)" || true
case "$said" in
    *"no package format nonsense"*) printf 'ok   a format it does not know is refused and named\n' ;;
    *)
        printf 'FAIL a format it does not know is refused and named: got "%s"\n' "$said"
        failed=$((failed + 1))
        ;;
esac

if [ "$failed" -ne 0 ]; then
    echo "$failed package-held-lib case(s) failed"
    exit 1
fi
echo "package-held-lib: all cases as expected"
