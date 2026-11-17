#!/bin/sh
# Tests what the FreeBSD packages do about the service, on the host: no machine, no pkg, no
# root (part of make check). The rc scripts run against a stand-in for rc.subr, the install
# scripts of the manifests run with stand-ins for service, sysrc and pw, and the documents are
# read. What rc.subr and pkg really do is proved in the machine, by scripts/freebsd-job.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
failed=0
tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT

# $1 what is tested, $2 the text wanted, $3 the text got.
same() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

# $1 what is tested, $2 the text, $3 the file or text that must hold it.
holds() {
    if printf '%s\n' "$3" | grep -qF -e "$2"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: "%s" is missing\n' "$1" "$2"
        failed=$((failed + 1))
    fi
}

# The program of each manifest and the name of its service, which is also the name of the rc
# script and the prefix of its setting.
programs='server splicefsd
client splicefs'

# --- the rc scripts -------------------------------------------------------------------------

# A stand-in for /etc/rc.subr that prints the setting the script ends up with. The real
# load_rc_config sets the variable from /etc/rc.conf before the script gives it a default; here
# the test's environment plays rc.conf.
cat > "$tree/rc.subr" <<'SUBR'
load_rc_config() { :; }
run_rc_command() { eval "printf '%s\n' \"\${$rcvar:-unset}\""; }
SUBR

# $1 the program, $2 its service, $3 the setting in rc.conf ("" for none). Prints the value
# of the setting.
rc_setting() {
    sed "s|/etc/rc.subr|$tree/rc.subr|" "programs/$1/freebsd/$2.rc" > "$tree/rc.script"
    if [ -n "$3" ]; then
        env "$2_enable=$3" sh "$tree/rc.script" start
    else
        env -u "$2_enable" sh "$tree/rc.script" start
    fi
}

while read -r program service; do
    got="$(rc_setting "$program" "$service" '')"
    same "$service: no setting in rc.conf means off, so installing turns nothing on" NO "$got"
    got="$(rc_setting "$program" "$service" YES)"
    same "$service: YES in rc.conf turns it on" YES "$got"
    got="$(rc_setting "$program" "$service" NO)"
    same "$service: NO in rc.conf keeps it off" NO "$got"
done <<PROGRAMS
$programs
PROGRAMS

# --- the install scripts of the manifests ---------------------------------------------------

# Prints the script named $3 of the manifest $1 as the build writes it, with the service name $2
# in place of @PROGRAM@.
manifest_script() {
    sed -n "/^  $3: <<EOD\$/,/^EOD\$/p" "$1" | sed -e '1d' -e '$d' -e "s|@PROGRAM@|$2|g"
}

# The names of the scripts of a manifest. Their lines start with two spaces; the lines of the
# messages start with more.
manifest_script_names() {
    sed -n 's/^  \([a-z-]*\): <<EOD$/\1/p' "$1"
}

# Runs a script with service, sysrc and pw that only record what they were asked. $1 the
# script text, $2 PKG_UPGRADE as pkg sets it ("true") or "" when it is not an upgrade.
# Prints what was called, each call followed by a semicolon, and the status after a slash.
run_script() {
    box="$tree/box"
    rm -rf "$box"
    mkdir -p "$box/bin"
    for tool in service sysrc pw; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 1\n' "$tool" "$box" > "$box/bin/$tool"
        chmod 755 "$box/bin/$tool"
    done
    : > "$box/calls"
    printf '%s\n' "$1" > "$box/script.sh"
    status=0
    if [ -n "$2" ]; then
        env PKG_UPGRADE="$2" PATH="$box/bin:$PATH" sh "$box/script.sh" >/dev/null 2>&1 || status=$?
    else
        env -u PKG_UPGRADE PATH="$box/bin:$PATH" sh "$box/script.sh" >/dev/null 2>&1 || status=$?
    fi
    calls="$(tr '\n' ';' < "$box/calls")"
    printf '%s/%s\n' "$calls" "$status"
}

while read -r program service; do
    manifest="programs/$program/freebsd/manifest.in"
    stop="$(manifest_script "$manifest" "$service" pre-deinstall)"
    # The stand-ins fail, so a script that let a failing command fail the removal shows it.
    got="$(run_script "$stop" '')"
    same "$service: removing the package stops the service and does not fail when it cannot" \
        "service $service onestop;/0" "$got"
    got="$(run_script "$stop" true)"
    same "$service: an upgrade leaves a running service running, because pkg cannot start it again" \
        "/0" "$got"

    # Whatever else the manifest runs, it neither starts the service nor touches rc.conf: the
    # administrator does both, as the install message says.
    for name in $(manifest_script_names "$manifest"); do
        for upgrade in '' true; do
            text="$(manifest_script "$manifest" "$service" "$name")"
            calls="$(run_script "$text" "$upgrade")"
            case "$calls" in
                *sysrc* | *"service $service start"* | *"service $service restart"* | *onestart*)
                    printf 'FAIL %s: %s (upgrade "%s") starts the service or edits rc.conf: %s\n' \
                        "$service" "$name" "$upgrade" "$calls"
                    failed=$((failed + 1)) ;;
                *) printf 'ok   %s: %s (upgrade "%s") does not start the service or edit rc.conf\n' \
                    "$service" "$name" "$upgrade" ;;
            esac
        done
    done
done <<PROGRAMS
$programs
PROGRAMS

# --- the messages of the manifests ----------------------------------------------------------

# Prints the message of type $3 of the manifest $1, for the service $2.
manifest_message() {
    awk -v type="$3" '
        index($0, "type: \"" type "\"") { found = 1 }
        found && /message: <<EOD$/ { reading = 1; next }
        reading && /^EOD$/ { exit }
        reading { print }
    ' "$1" | sed "s|@PROGRAM@|$2|g"
}

while read -r program service; do
    manifest="programs/$program/freebsd/manifest.in"
    text="$(manifest_message "$manifest" "$service" install)"
    holds "$service: the install message says how to turn it on and start it" \
        "sysrc ${service}_enable=YES && service $service start" "$text"
    text="$(manifest_message "$manifest" "$service" upgrade)"
    holds "$service: the upgrade message says how to restart it" "service $service restart" "$text"
    text="$(manifest_message "$manifest" "$service" remove)"
    holds "$service: the remove message says how to delete the setting" "sysrc -x ${service}_enable" "$text"
    if grep -q -e 'next boot' -e 'starts when the system boots' "$manifest"; then
        printf 'FAIL %s: the manifest still says that it runs by itself\n' "$service"
        failed=$((failed + 1))
    else
        printf 'ok   %s: the manifest does not say that it runs by itself\n' "$service"
    fi
done <<PROGRAMS
$programs
PROGRAMS

[ "$failed" -eq 0 ]
