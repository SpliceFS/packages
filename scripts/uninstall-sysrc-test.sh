#!/bin/sh
# check: uninstall steps for pkg: the sysrc lines of a service the test never turned on are left out, so no sysrc -x runs for an unset variable
# The removal of FreeBSD deletes the setting of each service from /etc/rc.conf, and the steps tell a
# person to leave out the line of a service never turned on. sysrc -x of a variable that is not set
# is an error ("unknown variable"), and the flag -i does not change that on FreeBSD. So the package
# test leaves out the line of each service its steps did not turn on (scripts/documented-removal-lib.sh),
# and the lines that remain run as written, in one shell with set -e as the documented removal has
# it, against a stand-in sysrc that fails for an unset variable as the real one does (what the real
# one does is proved in the machine, by scripts/freebsd-package-test.sh). It runs in milliseconds,
# with no FreeBSD.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
. scripts/documented-removal-lib.sh
steps_file=steps/uninstall-pkg.sh
own="$work"

# The stand-in keeps the settings in the file $RC_CONF, one NAME=VALUE to a line, and writes each
# call to $CALLS. -x deletes the variables it is given; one that is not in the file is an error, and
# -i, which the real sysrc takes for this case, does not make it succeed.
mkdir "$work/bin"
cat >"$work/bin/sysrc" <<'STAND_IN'
#!/bin/sh
echo "sysrc $*" >>"$CALLS"
delete=0
for argument; do
    case "$argument" in
        -i) ;;
        -x) delete=1 ;;
        *)
            [ "$delete" -eq 1 ] || { echo "sysrc: the stand-in only deletes" >&2; exit 2; }
            grep -q "^$argument=" "$RC_CONF" || { echo "sysrc: unknown variable '$argument'" >&2; exit 1; }
            grep -v "^$argument=" "$RC_CONF" >"$RC_CONF.new" || true
            mv "$RC_CONF.new" "$RC_CONF"
            ;;
    esac
done
STAND_IN
chmod 755 "$work/bin/sysrc"
RC_CONF="$work/rc.conf"
CALLS="$work/calls"
export RC_CONF CALLS

# Whether the lines of the documented removal that call sysrc, as the test would run them for the
# services in $turned_on, end well with the settings in $RC_CONF.
run_sysrc_lines() {
    text="$(documented_removal_text "$steps_file" "" "$1")"
    printf '%s\n' "$text" | grep '^sysrc ' >"$work/sysrc-lines" || true
    : >"$CALLS"
    status=0
    PATH="$work/bin:$PATH" sh -e "$work/sysrc-lines" >"$work/out" 2>&1 || status=$?
}

# $1 what is checked, $2 the programs whose service the steps turned on, then the settings the
# machine has (the steps set a service they turned on to NO when they disable it). The lines must
# succeed, no setting of a service that was turned on may be left, and the other settings stay.
case_of() {
    label="$1"
    turned_on="$2"
    shift 2
    printf '%s\n' 'hostname="box"' "$@" >"$RC_CONF"
    run_sysrc_lines "$turned_on"
    left="$(grep -c '^splicefsd*_enable=' "$RC_CONF" || true)"
    if [ "$status" -eq 0 ] && [ "$left" -eq 0 ] && grep -q '^hostname=' "$RC_CONF"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: status %s, %s settings of the services left, said "%s"\n' "$label" "$status" "$left" "$(cat "$work/out" || true)"
        failed=$((failed + 1))
    fi
}

# $1 what is checked, then the command that must succeed.
expect() {
    label="$1"
    shift
    if "$@"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s\n' "$label"
        failed=$((failed + 1))
    fi
}
has_line() { printf '%s\n' "$1" | grep -qx "$2"; }
never_called() { ! grep -q "$1" "$CALLS"; }

case_of "the server was turned on and disabled: its setting is deleted" server 'splicefsd_enable="NO"'
expect "the client's line was left out: sysrc never ran for it" never_called splicefs_enable
case_of "both were turned on and disabled" "server client" 'splicefsd_enable="NO"' 'splicefs_enable="NO"'
case_of "neither was turned on: no sysrc line is left" ""
expect "no sysrc call at all when neither was turned on" sh -c "! [ -s '$work/sysrc-lines' ] && ! [ -s '$CALLS' ]"

# The stand-in is as strict as the real sysrc, so the tests above prove something.
printf '%s\n' 'hostname="box"' >"$RC_CONF"
status=0
PATH="$work/bin:$PATH" sysrc -i -x splicefs_enable >/dev/null 2>&1 || status=$?
expect "the stand-in fails for an unset variable, with -i too, as sysrc does" test "$status" -eq 1

# What is reported as left out: the lines of the steps file of a service never turned on.
server_only="$(services_left_out "$steps_file" server)"
expect "the client's line is the one left out when only the server was turned on" \
    test "$server_only" = "sysrc -x splicefs_enable"
nothing_on="$(services_left_out "$steps_file" "")"
expect "the server's line is left out when nothing was turned on" has_line "$nothing_on" "sysrc -x splicefsd_enable"
expect "the client's line is left out when nothing was turned on" has_line "$nothing_on" "sysrc -x splicefs_enable"
both_on="$(services_left_out "$steps_file" "server client")"
expect "no line is left out when both were turned on" test -z "$both_on"
other_format="$(services_left_out steps/uninstall-apt.sh "")"
expect "a steps file with no sysrc line has none to leave out" test -z "$other_format"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "uninstall sysrc lines: all cases as expected"
