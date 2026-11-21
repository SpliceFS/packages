#!/bin/sh
# check: uninstall steps for pkg: the sysrc lines succeed for a service that was never enabled
# The removal of FreeBSD deletes the setting of each service from /etc/rc.conf, and a person who
# installed one program never enabled the service of the other. sysrc -x of a variable that is not
# set is an error ("unknown variable"), so the steps ask sysrc to ignore the unknown ones (-i),
# which is its own flag for this. The sysrc lines of steps/uninstall-pkg.sh run as written, one
# shell with set -e as the documented removal has it, against a stand-in sysrc that answers as
# the one of FreeBSD does (what the real one does is proved in the machine, by
# scripts/freebsd-package-test.sh). It runs in milliseconds, with no FreeBSD.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# The stand-in keeps the settings in the file $RC_CONF, one NAME=VALUE to a line. -x deletes the
# variables it is given; one that is not in the file is an error, unless -i says to ignore it.
mkdir "$work/bin"
cat >"$work/bin/sysrc" <<'STAND_IN'
#!/bin/sh
ignore=0
delete=0
for argument; do
    case "$argument" in
        -i) ignore=1 ;;
        -x) delete=1 ;;
        *)
            [ "$delete" -eq 1 ] || { echo "sysrc: the stand-in only deletes" >&2; exit 2; }
            if grep -q "^$argument=" "$RC_CONF"; then
                grep -v "^$argument=" "$RC_CONF" >"$RC_CONF.new" || true
                mv "$RC_CONF.new" "$RC_CONF"
            elif [ "$ignore" -eq 0 ]; then
                echo "sysrc: unknown variable '$argument'" >&2
                exit 1
            fi
            ;;
    esac
done
STAND_IN
chmod 755 "$work/bin/sysrc"
RC_CONF="$work/rc.conf"
export RC_CONF

# The lines of the steps file that call sysrc, as the file has them.
grep '^sysrc ' steps/uninstall-pkg.sh >"$work/sysrc-lines"
[ -s "$work/sysrc-lines" ] || { echo "FAIL steps/uninstall-pkg.sh has no sysrc line"; exit 1; }

# $1 what is checked, then the settings the machine has. The lines must succeed, and no setting of a
# service may be left.
case_of() {
    label="$1"
    shift
    printf '%s\n' 'hostname="box"' "$@" >"$RC_CONF"
    status=0
    PATH="$work/bin:$PATH" sh -e "$work/sysrc-lines" >"$work/out" 2>&1 || status=$?
    left="$(grep -c '^splicefsd*_enable=' "$RC_CONF" || true)"
    if [ "$status" -eq 0 ] && [ "$left" -eq 0 ] && grep -q '^hostname=' "$RC_CONF"; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s: status %s, %s settings of the services left, said "%s"\n' "$label" "$status" "$left" "$(cat "$work/out")"
        failed=$((failed + 1))
    fi
}

case_of "neither service was ever enabled"
case_of "only the server was enabled" 'splicefsd_enable="YES"'
case_of "only the client was enabled" 'splicefs_enable="YES"'
case_of "both were enabled" 'splicefsd_enable="YES"' 'splicefs_enable="YES"'
case_of "both were set to NO by the test before the removal" 'splicefsd_enable="NO"' 'splicefs_enable="NO"'

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "uninstall sysrc lines: all cases as expected"
