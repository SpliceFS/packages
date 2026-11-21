#!/bin/sh
# check: package-message-lib.sh: the install, upgrade and remove messages are read from the manifest of the package and checked against what pkg printed
# Test of scripts/package-message-lib.sh. The package files are tar files that hold a +MANIFEST written
# the ways pkg create may write it (compact or spread over lines, either order of the keys of a
# message), and what the package printed is a file of the case.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0
mkdir "$work/own"

# Makes the package file $1 from the manifest text $2.
make_package() {
    mkdir -p "$work/stage"
    printf '%s' "$2" >"$work/stage/+MANIFEST"
    tar -cf "$1" -C "$work/stage" +MANIFEST
}

compact='{"name":"splicefs-server","messages":[{"message":"Installed. Turn it on:\n\n    sysrc splicefsd_enable=YES && service splicefsd start\n","type":"install"},{"message":"Restart it:\n\n    service splicefsd restart\n","type":"upgrade"},{"message":"Left rc.conf alone. Delete the setting:\n\n    sysrc -x splicefsd_enable\n","type":"remove"}],"scripts":{}}'
spread='{
  "name": "splicefs-server",
  "messages": [
    {
      "type": "upgrade",
      "message": "Say \"restart\":\n    service splicefsd restart"
    },
    {
      "type": "install",
      "message": "turn on\n  sysrc splicefsd_enable=YES && service splicefsd start"
    }
  ]
}'
make_package "$work/compact.pkg" "$compact"
make_package "$work/spread.pkg" "$spread"
make_package "$work/none.pkg" '{"name":"splicefs-server"}'
make_package "$work/no-remove.pkg" '{"messages":[{"message":"only\n","type":"install"}]}'

# $1 case name, $2 package, $3 type, $4 the lines it must print, one to a line (empty: none and status 1).
reads() {
    status=0
    # package_message is one command whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    got="$(package_message "$2" "$3")" || status=$?
    if { [ -z "$4" ] && [ "$status" -ne 0 ]; } || { [ -n "$4" ] && [ "$status" -eq 0 ] && [ "$got" = "$4" ]; }; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: wanted "%s" got status %s and "%s"\n' "$1" "$4" "$status" "$got"
        failed=$((failed + 1))
    fi
}

# shellcheck source=package-message-lib.sh
. scripts/package-message-lib.sh
reads "a compact manifest: the install message, trimmed, with no empty line" "$work/compact.pkg" install "Installed. Turn it on:
sysrc splicefsd_enable=YES && service splicefsd start"
reads "a compact manifest: the upgrade message" "$work/compact.pkg" upgrade "Restart it:
service splicefsd restart"
reads "a compact manifest: the remove message" "$work/compact.pkg" remove "Left rc.conf alone. Delete the setting:
sysrc -x splicefsd_enable"
reads "a manifest spread over lines, the type first: the upgrade message, with its escaped quotes" "$work/spread.pkg" upgrade 'Say "restart":
service splicefsd restart'
reads "a manifest spread over lines: the install message" "$work/spread.pkg" install "turn on
sysrc splicefsd_enable=YES && service splicefsd start"
reads "a manifest with no message of the type wanted is found" "$work/spread.pkg" remove ""
reads "a manifest with no messages at all is found" "$work/none.pkg" install ""
reads "a manifest with messages of other types only is found" "$work/no-remove.pkg" upgrade ""

# $1 case name, $2 the format, $3 the lines pkg printed, $4 the type, $5 the command the adapter says the
# message of that type names, $6 what the check must say: ok, or the text of its refusal.
checks() {
    printf '%s\n' "$3" >"$work/printed"
    got="$(format="$2" own="$work/own" sh -c '
        fail() { echo "FAIL: $*"; exit 1; }
        . scripts/package-message-lib.sh
        command_named="$4"
        message_command() { echo "$command_named"; }
        check_package_message "$1" "$2" "$3"' sh "$4" "$work/printed" "$work/compact.pkg" "$5" 2>&1)" && status=ok || status=refused
    case "$status:$got" in
        "ok:"*"$6"* | "refused:"*"$6"*) printf 'ok   %s\n' "$1" ;;
        *)
            printf 'FAIL %s: wanted "%s" got %s: "%s"\n' "$1" "$6" "$status" "$got"
            failed=$((failed + 1))
            ;;
    esac
}

printed_install='===> Message from splicefs-server-1.2.3:
Installed. Turn it on:

    sysrc splicefsd_enable=YES && service splicefsd start
'
checks "pkg printed the install message of its manifest" pkg "$printed_install" install "service splicefsd start" "ok: the package printed its install message"
checks "pkg that printed another text is found" pkg "nothing useful" install "service splicefsd start" "does not hold the line of its install message: Installed. Turn it on:"
checks "pkg that printed the message without its command is found" pkg "Installed. Turn it on:" install "service splicefsd start" \
    "does not hold the line of its install message: sysrc splicefsd_enable=YES && service splicefsd start"
checks "a message that does not name the command the steps run is found" pkg "$printed_install" install "service other start" \
    "does not name the command: service other start"
checks "a package with no message of the type is found" pkg "x" upgrade-none "service" "holds no upgrade-none message"
checks "deb prints no message and nothing is checked" deb "nothing" install "service splicefsd start" ""
checks "rpm and apk the same" apk "nothing" remove "service splicefsd start" ""

if [ "$failed" -ne 0 ]; then
    echo "$failed package-message-lib case(s) failed"
    exit 1
fi
echo "package-message-lib: all cases as expected"
