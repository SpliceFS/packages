# shellcheck shell=sh
# Sourced by scripts/freebsd-job.sh inside the FreeBSD machine. It says what "the service
# works" means for this program; the rest of the job is the same for every SpliceFS program.

# scripts/freebsd-job.sh, which sources this file, reads expected_user.
# shellcheck disable=SC2034
# The client runs as root, as on Linux: mounting needs it.
expected_user=root

# Status 0 when the running client answers the status command over its control socket. A
# freshly installed client has no clusters and no mounts, and must still be there to ask.
answers() {
    /usr/local/bin/splicefsctl status >/dev/null 2>&1
}

# Checks that only the client needs, run by the job while the service is running and answering.
# They are about mounting from /etc/fstab at boot: the order of the boot, and a late line.
extra_checks() {
    check_work="$(mktemp -d)"
    check_rc_order
    check_late_line
}

# The line number of the script $1 in the list that rcorder wrote, or nothing when it is not in it.
rc_position() {
    awk -v wanted="$1" '$0 == wanted { print NR }' "$check_work/rcorder.out"
}

# rcorder is what /etc/rc runs to order the scripts, so its list is the order of the boot. The
# client must come before mountlate, which mounts the late fstab lines with the client's helper.
check_rc_order() {
    if ! rcorder /etc/rc.d/* /usr/local/etc/rc.d/* > "$check_work/rcorder.out" 2> "$check_work/rcorder.err"; then
        problems="$(cat "$check_work/rcorder.err")"
        fail "rcorder failed: $problems"
    fi
    own="$(rc_position /usr/local/etc/rc.d/splicefs)"
    late="$(rc_position /etc/rc.d/mountlate)"
    [ -n "$own" ] || fail "rcorder does not list /usr/local/etc/rc.d/splicefs"
    [ -n "$late" ] || fail "rcorder does not list /etc/rc.d/mountlate"
    [ "$own" -lt "$late" ] || fail "rcorder starts mountlate (number $late) before splicefs (number $own)"
    echo "rcorder: splicefs starts before mountlate"
}

# A late fstab line, written as the documents say, for a cluster that is not defined: the
# running client refuses it, and the refusal is the helper's own message, which shows that
# mount(8) ran the helper that mountprog= names and that the helper asked the client. The helper
# is the first link of the package.
check_late_line() {
    # The input folder is set by scripts/freebsd-job.sh, which sources this file.
    # shellcheck disable=SC2154
    helper="$(awk 'NR == 1 { print $1 }' "$in/links")"
    fstab_file="$check_work/fstab"
    mkdir "$check_work/files"
    # The line as the documents show it, with failok: a line that fails must not stop the boot.
    printf 'nocluster:/ %s/files splicefs ro,late,failok,mountprog=%s 0 0\n' "$check_work" "$helper" > "$fstab_file"
    # mount -a leaves late lines to mountlate, which would otherwise run before the client does.
    mount -a -F "$fstab_file" > "$check_work/plain.out" 2>&1 || true
    if grep -qF 'mount.splicefs:' "$check_work/plain.out"; then fail "mount -a ran the late line"; fi
    # mountlate runs mount -a -L; the cluster is not defined, so the helper is refused, and failok
    # must turn that into success, or the boot would stop.
    if ! mount -a -L -F "$fstab_file" > "$check_work/late.out" 2>&1; then
        cat "$check_work/late.out"
        fail "mount -a -L failed for a failok line: the boot would stop"
    fi
    if ! grep -qF 'mount.splicefs:' "$check_work/late.out"; then
        cat "$check_work/late.out"
        fail "mount -a -L did not run the helper $helper"
    fi
    if mount | grep -qF "$check_work/files"; then fail "a cluster that is not defined was mounted"; fi
    echo "mount -a -L: the late line ran the helper, was refused, and failok let the boot go on"
}
