#!/bin/sh
# Tests the install scripts that the packages get from the shared service steps in
# packaging/service: how scripts/package-lib.sh fills them in (package_script), and what the
# filled steps do, with stand-ins for systemctl and the OpenRC commands. Runs on the host, no
# Docker and no root (part of make check). What the steps do in a real system is proved by
# scripts/service-test.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
failed=0
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT

# A tiny repository: one program and one service manager whose steps are easy to recognize.
mkdir -p "$tree/scripts" "$tree/programs/demo" "$tree/packaging/service/mgr"
cp "$root/scripts/program-conf.sh" "$tree/scripts/"
cat > "$tree/programs/demo/program.conf" <<'CONF'
name=splicefs-demo
program=demod
programs=demod
docs=README.md
CONF
printf 'conf.d\n' > "$tree/programs/demo/config-folders"
printf 'first line of @SERVICE@\nsecond line\n\nafter a blank\n' > "$tree/packaging/service/mgr/step"

# $1 the file to fill in, $2 the folder that holds the repository (the tree or the real one),
# $3 the program, $4 the service manager. Prints what package_script prints, and its refusal.
filled() {
    # The inner shell expands $1 to $4, which are the arguments above.
    # shellcheck disable=SC2016
    (cd "$2" && PROGRAM="$3" VERSION=v1.2.3 PACKAGE_DATE=20261112 REVISION=0 sh -c \
        '. "$1/scripts/package-lib.sh"; package_script "$2" "$3"' sh "$root" "$4" "$1" 2>&1) || true
}

# $1 what is tested, $2 the text wanted, $3 the text got.
same() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

# The text is the script that is written, not for this shell to expand.
# shellcheck disable=SC2016
printf '#!/bin/sh\nset -e\ncase "$1" in\n    configure)\n        @service:step@\n        ;;\nesac\n' > "$tree/with-step"
# shellcheck disable=SC2016
want='#!/bin/sh
set -e
case "$1" in
    configure)
        first line of demod
        second line

        after a blank
        ;;
esac'
got="$(filled "$tree/with-step" "$tree" demo mgr)"
same 'a placeholder is replaced by the step, indented like the placeholder, with the service name' "$want" "$got"
printf 'no placeholder here\n  @SERVICE@ is not one\n' > "$tree/plain"
got="$(filled "$tree/plain" "$tree" demo mgr)"
same 'a file without a placeholder comes out unchanged' 'no placeholder here
  @SERVICE@ is not one' "$got"
printf '@service:nothing@\n' > "$tree/unknown"
got="$(filled "$tree/unknown" "$tree" demo mgr)"
same 'a step that does not exist is refused' 'FAIL: packaging/service/mgr/nothing does not exist' "$got"

# What the steps do. $1 the program, $2 the service manager, $3 the step, $4 whether the service
# manager runs (yes or no), $5 the status its commands end with, $6 the commands wanted, each
# followed by a semicolon.
# The steps look for the running service manager at fixed paths, which a test host does not have,
# so the paths are moved into a folder of the test. That the real paths are the right ones is
# proved by scripts/service-test.sh.
behaves() {
    box="$tree/box"
    rm -rf "$box"
    mkdir -p "$box/bin"
    for tool in systemctl rc-service rc-update; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit %s\n' "$tool" "$box" "$5" > "$box/bin/$tool"
        chmod 755 "$box/bin/$tool"
    done
    : > "$box/calls"
    if [ "$4" = yes ]; then
        mkdir -p "$box/run/systemd/system"
        mkdir -p "$box/run/openrc"
        : > "$box/run/openrc/softlevel"
    fi
    printf '@service:%s@\n' "$3" > "$box/step.in"
    filled "$box/step.in" "$root" "$1" "$2" |
        sed -e "s|/run/systemd/system|$box/run/systemd/system|" \
            -e "s|/run/openrc/softlevel|$box/run/openrc/softlevel|" > "$box/step.sh"
    status=0
    PATH="$box/bin:$PATH" sh "$box/step.sh" 2>/dev/null || status=$?
    got="$(tr '\n' ';' < "$box/calls")"
    same "$1: $2 $3, service manager running: $4, its commands end with $5: ends with 0 and runs '$6'" \
        "$6" "$got/$status"
}

# Every row is run for both programs, whose service names differ.
while read -r program service; do
    # A step is a no-op where no service manager runs, whatever else is true.
    behaves "$program" systemd after-files no 0 "/0"
    behaves "$program" systemd before-removal no 0 "/0"
    behaves "$program" systemd after-removal no 0 "/0"
    behaves "$program" openrc after-files no 0 "/0"
    behaves "$program" openrc before-removal no 0 "/0"
    # Installing never enables or starts: no row has an enable or a start in it.
    behaves "$program" systemd after-files yes 0 "systemctl daemon-reload;systemctl try-restart $service.service;/0"
    behaves "$program" systemd before-removal yes 0 "systemctl disable --now $service.service;/0"
    behaves "$program" systemd after-removal yes 0 "systemctl daemon-reload;/0"
    behaves "$program" openrc after-files yes 0 "rc-service --ifstarted $service restart;/0"
    behaves "$program" openrc before-removal yes 0 \
        "rc-service --ifstarted $service stop;rc-update -qq del $service default;/0"
    # A service manager that fails must never fail the install or the removal.
    behaves "$program" systemd after-files yes 1 "systemctl daemon-reload;systemctl try-restart $service.service;/0"
    behaves "$program" systemd before-removal yes 1 "systemctl disable --now $service.service;/0"
    behaves "$program" systemd after-removal yes 1 "systemctl daemon-reload;/0"
    behaves "$program" openrc after-files yes 1 "rc-service --ifstarted $service restart;/0"
    behaves "$program" openrc before-removal yes 1 \
        "rc-service --ifstarted $service stop;rc-update -qq del $service default;/0"
done <<PROGRAMS
server splicefsd
client splicefs
PROGRAMS

# The scripts of the programs as the packages get them: every placeholder is filled in, none of
# them enables or starts the service (installing never does), and the shell scripts parse. $1 the
# file, $2 the service manager, $3 the program, $4 shell for a script and spec for the rpm spec,
# which is not a shell script.
builds() {
    filled "$1" "$root" "$3" "$2" > "$tree/built"
    reason=''
    if grep -q -e '@service:' -e '@SERVICE@' "$tree/built"; then
        reason='keeps a placeholder'
    elif grep -q -e 'systemctl enable' -e 'systemctl start' -e 'rc-update add' -e 'rc-service [a-z]* start' "$tree/built"; then
        reason='enables or starts the service'
    elif [ "$4" = shell ] && ! sh -n "$tree/built"; then
        reason='does not parse'
    fi
    if [ -z "$reason" ]; then
        printf 'ok   %s builds into what a package gets\n' "$1"
    else
        printf 'FAIL %s %s\n' "$1" "$reason"
        failed=$((failed + 1))
    fi
}

for program in server client; do
    for script in postinst prerm postrm; do
        builds "programs/$program/deb/$script" systemd "$program" shell
    done
    for script in "programs/$program/alpine/splicefs-$program".*; do
        builds "$script" openrc "$program" shell
    done
    builds "programs/$program/rpm/splicefs-$program.spec" systemd "$program" spec
done

[ "$failed" -eq 0 ]
