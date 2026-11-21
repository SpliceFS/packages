#!/bin/sh
# check: freebsd-package-test-host-lib.sh: what goes into the input archive and the job folder of a FreeBSD machine, and which package of a release is tested
# Test of scripts/freebsd-package-test-host-lib.sh, the host's part of scripts/freebsd-package-test.sh:
# the package file of a program and a release, the input archive (the fourth disk of the machine) and
# the job folder (its first disk). The repository is made of links to the real scripts and
# definitions, with a record and a package file for each program, and docker is a stand-in that
# answers with the templates of the image, so it needs no Docker, no machine and no network, and runs
# in milliseconds (part of make check).
# The dollar signs of the cases are the text of a script, not ours.
# shellcheck disable=SC2016
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failed=0

mkdir -p "$t/repo" "$t/baselines" "$t/bin"
for each in scripts programs steps keys packaging setup.sh.in; do ln -s "$root/$each" "$t/repo/$each"; done
mkdir -p "$t/repo/dist/server/freebsd/FreeBSD-15-amd64" "$t/repo/dist/server/freebsd/FreeBSD-14-amd64" "$t/repo/dist/client/freebsd/FreeBSD-15-amd64"
printf 'VERSION=v1.2.3\nPACKAGE_DATE=20261112\nUPGRADE_FROM=1.2.2\n' >"$t/repo/dist/server/version"
printf 'VERSION=v1.4.0\nPACKAGE_DATE=20261113\nUPGRADE_FROM=none\n' >"$t/repo/dist/client/version"
echo 1.2.2 >"$t/baselines/server"
: >"$t/baselines/client"

# The name of the package file of a program is the library's to say, so the test asks it.
package_name() {
    (
        cd "$t/repo"
        platform=freebsd/amd64 baselines="$t/baselines" sh -c '. scripts/package-record.sh
. scripts/package-test-program-lib.sh
use_program "$1"
echo "$name-$pkgver.pkg"' sh "$1"
    )
}
server_package="$(package_name server)"
client_package="$(package_name client)"
echo server15 >"$t/repo/dist/server/freebsd/FreeBSD-15-amd64/$server_package"
echo server14 >"$t/repo/dist/server/freebsd/FreeBSD-14-amd64/$server_package"
echo client15 >"$t/repo/dist/client/freebsd/FreeBSD-15-amd64/$client_package"

# docker answers the two templates that the image of a release holds, and nothing else.
cat >"$t/bin/docker" <<'STAND_IN'
#!/bin/sh
echo "docker $*" >>"$CALLS"
case "$*" in
    *"cat /freebsd/user-data.in") echo 'sh /in/@JOB@ @ARGS@' ;;
    *"cat /freebsd/second-boot.in") [ -z "${NO_SECOND_BOOT:-}" ] || exit 1; echo 'second boot template' ;;
    *) exit 1 ;;
esac
STAND_IN
chmod 755 "$t/bin/docker"

# Runs the shell text $1 in the repository with the library of the host's part loaded, as the driver does
# (with errexit); prints what it prints and the status.
host() {
    (
        cd "$t/repo"
        # fail is the driver's own; it is defined before the library is sourced.
        CALLS="$t/calls" PATH="$t/bin:$PATH" FREEBSD_IMAGE='registry.invalid/freebsd-@RELEASE@:t1' \
            root="$t/repo" work="$t/work" baselines="$t/baselines" platform=freebsd/amd64 sh -c "
set -eu
fail() { echo \"FAIL: \$*\" >&2; exit 1; }
mkdir -p \"\$work\"
. scripts/package-record.sh
. scripts/package-test-program-lib.sh
. scripts/freebsd-lib.sh
. scripts/freebsd-package-test-host-lib.sh
$1" 2>&1
    ) || echo "status $?"
}

# $1 case name, $2 what the case printed, $3 the text it must hold.
holds() {
    case "$2" in
        *"$3"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted [%s] in:\n%s\n' "$1" "$3" "$2"
            failed=$((failed + 1))
            ;;
    esac
}
# $1 case name, $2 a file, $3 the text it must hold.
holds_file() {
    file_text="$(cat "$2" 2>/dev/null)" || file_text="(no file $2)"
    holds "$1" "$file_text" "$3"
}
# $1 case name, then the command that must succeed.
check() {
    check_name="$1"
    shift
    if "$@"; then
        printf 'ok   %s\n' "$check_name"
    else
        printf 'FAIL %s\n' "$check_name"
        failed=$((failed + 1))
    fi
}
# $1 case name, $2 what the case printed, $3 the text it must not hold.
lacks() {
    case "$2" in
        *"$3"*)
            printf 'FAIL %s: [%s] is in:\n%s\n' "$1" "$3" "$2"
            failed=$((failed + 1))
            ;;
        *) printf 'ok   %s\n' "$1" ;;
    esac
}

# --- package_of ---

got="$(host 'package_of server 15')"
holds "the package of a program and a release is its file in the folder of the release" "$got" "dist/server/freebsd/FreeBSD-15-amd64/$server_package"
got="$(host 'package_of server 16; echo done')"
holds "a release with no package of the program gives nothing" "$got" "done"
lacks "a release with no package of the program gives no path" "$got" "dist/"
rm -rf "$t/repo/dist/ghost"
got="$(host 'package_of ghost 15; echo done')"
holds "a program that was not built gives nothing and ends nothing" "$got" "done"
lacks "a program that was not built gives no path" "$got" "FAIL"

# --- make_input ---

host 'make_input 15 "$work/input.tar" server client' >"$t/made"
tar -tf "$t/work/input.tar" >"$t/listing"
listing="$(cat "$t/listing")"
has() {
    check "the input archive holds $1" grep -q "/$1\$" "$t/listing"
}
for wanted in src/scripts/freebsd-package-test-lib.sh src/scripts/package-test-steps.sh src/programs/server/program.conf \
    src/steps/uninstall-pkg.sh src/keys/splicefs.rsa.pub src/packaging/freebsd/releases src/setup.sh.in \
    src/dist/server/version src/dist/client/version "pkg/server/$server_package" "pkg/client/$client_package" \
    baselines/server baselines/client; do
    has "$wanted"
done
unpacked="$t/unpacked"
mkdir "$unpacked"
tar -xf "$t/work/input.tar" -C "$unpacked"
holds_file "the package of the release is the one of the program" "$unpacked/pkg/server/$server_package" server15
holds_file "the record of the build goes along: the steps choose the program by it" "$unpacked/src/dist/server/version" "VERSION=v1.2.3"
holds_file "the baseline of a program is its version" "$unpacked/baselines/server" 1.2.2
check "nothing published is an empty baseline file" test ! -s "$unpacked/baselines/client"
lacks "the package of another release stays out" "$listing" server14
lacks "the archive holds no packages in the source folder" "$listing" src/dist/server/freebsd

host 'make_input 15 "$work/server-only.tar" server' >"$t/made"
only="$(tar -tf "$t/work/server-only.tar")"
holds "an archive for the server holds its package" "$only" "pkg/server/$server_package"
lacks "an archive for the server holds no package of the client" "$only" "pkg/client"
lacks "an archive for the server holds no baseline of the client" "$only" "baselines/client"

# A program with no package of the release is not left out quietly: the archive would test less than it says.
got="$(host 'make_input 14 "$work/none.tar" client')"
holds "an archive for a program with no package of the release is refused" "$got" "status"

# A run of the client alone has no server package to put in: the machine fetches the newest published server as the
# fixture, so the archive holds its record (made in the folder of the records, no build made one), its baseline
# and the word that names it, and no package file. The records are read from the folder the host names.
rm -rf "$t/records" "$t/unpacked-fixture"
mkdir -p "$t/records/client" "$t/records/server"
cp "$t/repo/dist/client/version" "$t/records/client/version"
printf 'VERSION=v9.9.9\nPACKAGE_DATE=20260101\nUPGRADE_FROM=1.1.0\n' >"$t/records/server/version"
echo 1.1.0 >"$t/baselines/server"
host "record_folder=$t/records; fixtures=server; make_input 15 \"\$work/fixture.tar\" client" >"$t/made"
mkdir "$t/unpacked-fixture"
tar -xf "$t/work/fixture.tar" -C "$t/unpacked-fixture"
holds_file "the fixture is named in the archive" "$t/unpacked-fixture/fixtures" server
holds_file "the record of the fixture goes along, from the folder of the records" "$t/unpacked-fixture/src/dist/server/version" "VERSION=v9.9.9"
holds_file "the baseline of the fixture is its newest published version" "$t/unpacked-fixture/baselines/server" 1.1.0
check "the fixture has no package file in the archive" test ! -e "$t/unpacked-fixture/pkg/server"
holds_file "the program under test is still in the archive" "$t/unpacked-fixture/pkg/client/$client_package" client15
check "a run with no fixture names none" sh -c "[ -f '$unpacked/fixtures' ] && [ ! -s '$unpacked/fixtures' ]"
got="$(host "record_folder=$t/records; package_of client 15")"
holds "the record of a program is read from the folder of the records" "$got" "dist/client/freebsd/FreeBSD-15-amd64/$client_package"

# --- make_job_folder ---

host 'make_job_folder 15.1 "$work/job" server client' >"$t/made"
job="$t/work/job"
holds_file "the job folder holds the job of the first boot" "$job/freebsd-package-test-job.sh" "The first boot of the package test on FreeBSD"
holds_file "the job folder holds the file of the second boot" "$job/freebsd-package-test-second.sh" "second boot"
holds_file "the job folder holds the template of the second boot that the image provides" "$job/second-boot.in" "second boot template"
holds_file "user-data starts the job with the programs" "$job/user-data" "sh /in/freebsd-package-test-job.sh server client"
holds_file "the templates are asked of the image of the release" "$t/calls" "docker run --rm registry.invalid/freebsd-15.1:t1 cat /freebsd/second-boot.in"
rm -f "$t/calls"
got="$(host 'export NO_SECOND_BOOT=1; make_job_folder 15.1 "$work/job-old" server')"
holds "an image with no template of the second boot is named as too old" "$got" "the image is too old for a second boot"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "freebsd package test host lib: all cases as expected"
