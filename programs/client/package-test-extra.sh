# shellcheck shell=sh
# Sourced by scripts/package-test-<format>.sh after the package is installed.
# mount(8) looks for its helpers in the helper folder of the format (helperdir of the table in
# scripts/package-lib.sh). On Linux that is /sbin, which on some systems is a link to /usr/sbin and
# on others a folder of its own; on FreeBSD it is under /usr/local. Either way the helper must be
# found there and must be the control tool: asked for nothing, it answers with its usage and status 1.
# helperdir is set by scripts/package-lib.sh, which ShellCheck cannot follow from here.
# shellcheck disable=SC2154
helper="$helperdir/mount.splicefs"
[ -x "$helper" ] || fail "$helper is missing"
if "$helper" >/dev/null 2>&1; then fail "mount.splicefs without arguments succeeded"; fi
# It exits with status 1 here, as the check above requires; only its output is looked at.
usage="$("$helper" 2>&1)" || true
printf '%s\n' "$usage" | grep -q "mount.splicefs" || fail "mount.splicefs does not print its usage"
