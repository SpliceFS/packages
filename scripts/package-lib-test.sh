#!/bin/sh
# Table test of how scripts/package-lib.sh turns VERSION into each package version. Runs on
# the host, no Docker (make package-lib-test, part of make check). Whether the results also
# sort right in each package manager is checked in containers by scripts/package-order-test.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
failed=0
# The version and unit tests below use the programs of this repository.
PROGRAM=server
export PROGRAM

# Which program is packaged is said by PROGRAM and read from programs/PROGRAM/program.conf, and
# nothing else: not the folder names of the repository, not another program's files. The
# fixture holds two programs that differ in everything, so a value that came from anywhere but
# the file of the program asked for shows.
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
mkdir -p "$tree/programs/demo/systemd" "$tree/programs/other" "$tree/programs/empty"
cat > "$tree/programs/demo/program.conf" <<'CONF'
name=splicefs-demo
program=demod
programs="demod democtl"
docs="README.md guide/setup.md"
CONF
printf '# a comment\n\nalpha.d\nbeta.d\n' > "$tree/programs/demo/config-folders"
printf 'ExecStart=/usr/local/bin/demod\n' > "$tree/programs/demo/systemd/demod.service"
cat > "$tree/programs/other/program.conf" <<'CONF'
name=splicefs-other
program=otherd
programs=otherd
docs=README.md
CONF
printf 'gamma.d\n' > "$tree/programs/other/config-folders"
# A program.conf that leaves a fact out.
printf 'program=x\nprograms=x\ndocs=x\n' > "$tree/programs/empty/program.conf"

# $1 the folder the library is read from (the root of a repository), $2 PROGRAM, $3 the facts
# wanted: name, program, programs, docs, confdir and confsubdirs on one line (the folders joined
# by a comma).
reads() {
    got="$(cd "$1" && PROGRAM="$2" VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. "$1/scripts/package-lib.sh"; echo "$name|$program|$programs|$docs|$confdir|$(echo $confsubdirs | tr " " ,)"' \
        sh "$root" 2>&1)" || true
    if [ "$got" = "$3" ]; then
        printf 'ok   program.conf of %-6s %s\n' "$2" "$3"
    else
        printf 'FAIL program.conf of %s: want "%s" got "%s"\n' "$2" "$3" "$got"
        failed=$((failed + 1))
    fi
}

# $1 text the refusal must contain, the rest the arguments of env that set up the case.
refuses_program() {
    text="$1"
    shift
    # The inner shell expands $1, which is the root of the repository.
    # shellcheck disable=SC2016
    if got="$(cd "$tree" && env "$@" VERSION=v1.2.3 PACKAGE_DATE=20261112 \
        sh -c '. "$1/scripts/package-lib.sh"' sh "$root" 2>&1)"; then
        printf 'FAIL %s was accepted\n' "$*"
        failed=$((failed + 1))
    elif printf '%s' "$got" | grep -q -- "$text"; then
        printf 'ok   %s refused: %s\n' "$*" "$got"
    else
        printf 'FAIL %s refused with the wrong message: %s\n' "$*" "$got"
        failed=$((failed + 1))
    fi
}

reads "$tree" demo 'splicefs-demo|demod|demod democtl|README.md guide/setup.md|/etc/splicefs/demo|alpha.d,beta.d'
reads "$tree" other 'splicefs-other|otherd|otherd|README.md|/etc/splicefs/other|gamma.d'
reads "$root" server 'splicefs-server|splicefsd|splicefsd|README.md CHANGELOG.md docs/configuration.md|/etc/splicefs/server|conf.d,shares.d'
refuses_program 'PROGRAM is not set' -u PROGRAM
refuses_program 'programs/nothing/program.conf' PROGRAM=nothing
refuses_program 'not a program name' PROGRAM=../demo
refuses_program 'not a program name' PROGRAM=demo/
refuses_program 'programs/empty/program.conf does not set name' PROGRAM=empty

# The documents a package ships are named in program.conf and found in the source tree SRC. $1
# the paths or the message wanted, the rest the arguments of env that set up the case.
docs_of() {
    want="$1"
    shift
    # The inner shell expands $1, which is the root of the repository.
    # shellcheck disable=SC2016
    got="$(cd "$tree" && env "$@" PROGRAM=demo VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. "$1/scripts/package-lib.sh"; package_docs' sh "$root" 2>&1)" || true
    if [ "$got" = "$want" ]; then
        printf 'ok   package_docs with %s: %s\n' "$*" "$want"
    else
        printf 'FAIL package_docs with %s: want "%s" got "%s"\n' "$*" "$want" "$got"
        failed=$((failed + 1))
    fi
}

docs_of '/work/demo/README.md /work/demo/guide/setup.md' SRC=/work/demo
docs_of 'FAIL: SRC is not set: it is the source tree of the program at this version' -u SRC

# The links a program installs are named in its own links file, "<link> <target>" a line, and
# are made by one function for every package format. $1 the folder the library is read from, $2 the
# program, $3 what is wanted: the links under the root it is given, as "<link> -> <target>" items
# each followed by a comma, or nothing.
links_of() {
    # The inner shell expands $1 and $2, which are the root of the repository and the link root.
    # shellcheck disable=SC2016
    got="$(cd "$1" && PROGRAM="$2" VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. "$1/scripts/package-lib.sh"; package_links "$2"; cd "$2" && find . -type l | LC_ALL=C sort |
            while read -r l; do echo "${l#.} -> $(readlink "$l")"; done | tr "\n" ,' \
        sh "$root" "$linkroot" 2>&1)" || true
    rm -rf "${linkroot:?}"/*
    if [ "$got" = "$3" ]; then
        printf 'ok   package_links of %-6s %s\n' "$2" "$3"
    else
        printf 'FAIL package_links of %s: want "%s" got "%s"\n' "$2" "$3" "$got"
        failed=$((failed + 1))
    fi
}

printf '# a comment\n\n/usr/sbin/mount.demo /usr/bin/democtl\n/usr/lib/demo/helper /usr/bin/demod\n' \
    > "$tree/programs/demo/links"
linkroot="$tree/linkroot"
mkdir "$linkroot"
links_of "$tree" demo '/usr/lib/demo/helper -> /usr/bin/demod,/usr/sbin/mount.demo -> /usr/bin/democtl,'
# A program without a links file has no links, and that is no error.
links_of "$tree" other ''
links_of "$root" server ''

# $1 VERSION, $2 deb and rpm version, $3 Alpine version, $4 FreeBSD version (PACKAGE_DATE is
# 20261112).
check() {
    got="$(VERSION="$1" PACKAGE_DATE=20261112 sh -c \
        '. scripts/package-lib.sh; echo "$debver $rpmver $apkver $pkgver"' 2>&1)" || true
    want="$2 $2 $3 $4"
    if [ "$got" = "$want" ]; then
        printf 'ok   %-28s deb/rpm %-26s apk %-24s pkg %s\n' "$1" "$2" "$3" "$4"
    else
        printf 'FAIL %-28s want "%s" got "%s"\n' "$1" "$want" "$got"
        failed=$((failed + 1))
    fi
}

# $1 VERSION that must be refused, $2 text the message must contain.
refuse() {
    if got="$(VERSION="$1" PACKAGE_DATE=20261112 sh -c '. scripts/package-lib.sh' 2>&1)"; then
        printf 'FAIL %-28s was accepted\n' "$1"
        failed=$((failed + 1))
    elif printf '%s' "$got" | grep -q -- "$2"; then
        printf 'ok   %-28s refused: %s\n' "$1" "$got"
    else
        printf 'FAIL %-28s refused with the wrong message: %s\n' "$1" "$got"
        failed=$((failed + 1))
    fi
}

check v1.2.3 1.2.3 1.2.3 1.2.3
check v1.2.3-rc.1 1.2.3~rc.1 1.2.3_rc1 1.2.3.rc1
check v1.2.3-beta.2 1.2.3~beta.2 1.2.3_beta2 1.2.3.beta2
check v1.2.3-alpha 1.2.3~alpha 1.2.3_alpha 1.2.3.alpha
check v1.2.3-dirty 1.2.3+dirty 1.2.3_git20261112 1.2.3.20261112
check v1.2.3-rc.1-dirty 1.2.3~rc.1+dirty 1.2.3_rc1_git20261112 1.2.3.rc1.20261112
refuse v1.2.3-foo.1 v1.2.3-foo.1
refuse v1.2 v1.2
refuse v1.2.3-rc.1.2 v1.2.3-rc.1.2
# What git describe prints between releases and without tags is not a version any more; a
# build that gets one has not read the file VERSION.
refuse v1.2.3-4-gabc1234 v1.2.3-4-gabc1234
refuse abc1234 abc1234
refuse abc1234-dirty abc1234-dirty
refuse dev dev
refuse 1.2.3 1.2.3

# The unit in the repository is written for a manual install under /usr/local; the unit a
# package ships has the program in /usr/bin, and nothing else is lost.
got="$(VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c '. scripts/package-lib.sh; package_unit /dev/stdout' 2>&1)" || true
got_lines="$(printf '%s\n' "$got" | wc -l)"
repo_lines="$(wc -l < programs/server/systemd/splicefsd.service)"
if printf '%s\n' "$got" | grep -qx 'ExecStart=/usr/bin/splicefsd' &&
    ! printf '%s\n' "$got" | grep -q '/usr/local/' && [ "$got_lines" -eq "$repo_lines" ]; then
    echo "ok   the packaged unit has the program in /usr/bin"
else
    printf 'FAIL the packaged unit has the wrong program path or lost lines: %s\n' "$got"
    failed=$((failed + 1))
fi

# ONLY limits a run to one format or one image, for every script that walks packaging/test-systems.
# $1 ONLY, $2 format, $3 image, $4 selected (yes or no).
selects() {
    if ONLY="$1" VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. scripts/package-lib.sh; system_selected "$1" "$2"' sh "$2" "$3"; then got=yes; else got=no; fi
    if [ "$got" = "$4" ]; then
        printf 'ok   ONLY="%s" %s %s: %s\n' "$1" "$2" "$3" "$got"
    else
        printf 'FAIL ONLY="%s" %s %s: want %s got %s\n' "$1" "$2" "$3" "$4" "$got"
        failed=$((failed + 1))
    fi
}

selects "" deb ghcr.io/splicefs/server-debian-12:v1.0 yes
selects deb deb ghcr.io/splicefs/server-debian-12:v1.0 yes
selects rpm deb ghcr.io/splicefs/server-debian-12:v1.0 no
selects ghcr.io/splicefs/server-debian-12:v1.0 deb ghcr.io/splicefs/server-debian-12:v1.0 yes
selects ghcr.io/splicefs/server-debian-12:v1.0 deb ghcr.io/splicefs/server-ubuntu-24.04:v1.0 no
# A part of a name is not a name: the filter says which format or which image, not a pattern.
selects deb rpm ghcr.io/splicefs/server-amazonlinux-2023:v1.0 no
selects server-rocky-9 rpm ghcr.io/splicefs/server-rocky-9:v1.0 no

# A system is started the way the images README boots a server image, and the test waits for
# its service manager the way that manager reports it. A stand-in for docker records what it
# is asked and answers as a system in the state given by the variables of each case.
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
cat > "$fake/docker" <<'DOCKER'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case "$1 $3" in
    "exec systemctl") echo "$FAKE_SYSTEMD" ;;
    "exec rc-status") echo "$FAKE_RUNLEVEL" ;;
    "inspect "*) echo "$FAKE_RUNNING" ;;
    *) ;;
esac
DOCKER
chmod +x "$fake/docker"

# $1 what is passed to boot_system, $2 the command line docker must get.
boots() {
    : > "$fake/log"
    # $1 is split on purpose: it holds several arguments.
    # shellcheck disable=SC2086
    got="$(PATH="$fake:$PATH" FAKE_LOG="$fake/log" VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. scripts/package-lib.sh; boot_system "$@"' sh $1 2>&1 && cat "$fake/log")" || true
    if [ "$got" = "$2" ]; then
        printf 'ok   boot_system %s\n' "$1"
    else
        printf 'FAIL boot_system %s: want "%s" got "%s"\n' "$1" "$2" "$got"
        failed=$((failed + 1))
    fi
}

# $1 format, $2 state of systemd, $3 runlevel of OpenRC, $4 whether the container runs,
# $5 the status wait_booted must return. Each case is ready at once or never, so none waits.
waits() {
    : > "$fake/log"
    got=0
    PATH="$fake:$PATH" FAKE_LOG="$fake/log" FAKE_SYSTEMD="$2" FAKE_RUNLEVEL="$3" FAKE_RUNNING="$4" \
        VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c '. scripts/package-lib.sh; wait_booted "$1" box' sh "$1" >/dev/null 2>&1 || got=$?
    if [ "$got" -eq "$5" ]; then
        printf 'ok   wait_booted %-4s systemd=%-8s runlevel=%-8s running=%-5s status %s\n' "$1" "$2" "$3" "$4" "$got"
    else
        printf 'FAIL wait_booted %-4s systemd=%-8s runlevel=%-8s running=%-5s want status %s got %s\n' \
            "$1" "$2" "$3" "$4" "$5" "$got"
        failed=$((failed + 1))
    fi
}

boots "--name box ghcr.io/splicefs/server-debian-12:v1.0" "run -d --privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock --tmpfs /tmp --name box ghcr.io/splicefs/server-debian-12:v1.0"
waits deb running "" true 0
waits rpm degraded "" true 0
waits apk "" default true 0
# A format is waited for with its own service manager: the other one's answer does not count.
waits apk running "" false 1
waits deb "" default false 1
# A container that has stopped will never be ready, so the wait ends at once.
waits deb starting "" false 1
waits apk "" boot false 1

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "package versions: all mappings as expected"
