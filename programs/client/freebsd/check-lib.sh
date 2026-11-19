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
    check_user_mode
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

# --- the client run by an ordinary user ---------------------------------------------------------

# "Run as yourself" in the install instructions: the steps the administrator takes once, as root,
# and then the client started by the user. The commands below are the ones the instructions show,
# for the user they name; scripts/freebsd-service-test.sh compares them with the README and
# steps/user-mode-start.sh. The machine has no cluster, and the cluster of the instructions is only
# defined: a client with no mounts does not contact it, so the address stays as it is.
user_mode_user=alice

# One command to a line, run one at a time by user_mode_root_steps.
user_mode_root_text() {
    cat <<'ROOT_STEPS'
sysctl vfs.usermount=1
echo 'vfs.usermount=1' >> /etc/sysctl.conf
sysrc kld_list+=fusefs && kldload -n fusefs
pw groupmod operator -m alice
printf '[fuse_users=10]\nadd path fuse mode 0660 group operator\n' >> /etc/devfs.rules
sysrc devfs_system_ruleset=fuse_users && service devfs restart
ROOT_STEPS
}

# The block the user runs, as steps/user-mode-start.sh has it.
user_mode_start_text() {
    cat <<'START_STEPS'
# Your own folders, in your home directory: your cluster and its password.
config="${XDG_CONFIG_HOME:-$HOME/.config}/splicefs/client"
mkdir -p "$config/clusters.d" "$config/secrets" ~/files

# Your cluster. The file name is the cluster name.
cat > "$config/clusters.d/example.yaml" <<'EOF'
url: "https://east.example.com/api"
user: alice
password_file: secrets/example
EOF
(umask 077; cat > "$config/secrets/example")   # type the password, then Ctrl-D

# Start the client as yourself. It stays in the foreground: give it a terminal of its own.
splicefs
START_STEPS
}

# Runs the command line $1 as the user, with the user's home folder. su reads the groups of the user
# afresh, so the group the root steps gave is there without a login. A login shell is not used: it
# reads the profile of the user, and the profile of a new FreeBSD user prints a fortune, which
# would come before the output of the command, and the checks read that output.
as_user() {
    su "$user_mode_user" -c "$1"
}

# Status 0 when the client of the user answers over the socket it finds by itself.
user_client_answers() {
    as_user 'splicefsctl status'
}

# The root steps as documented, and what they are for: the user, the mount permission, the
# module, the group and the device. Every step must succeed: kldload -n does nothing when the
# service of this machine has loaded fusefs already.
user_mode_prepare() {
    pw useradd "$user_mode_user" -m -s /bin/sh || fail "pw could not add $user_mode_user"
    user_mode_root_text > "$check_work/root-steps"
    while IFS= read -r step; do
        sh -c "$step" < /dev/null || fail "the documented step failed: $step"
    done < "$check_work/root-steps"
    usermount="$(sysctl -n vfs.usermount)"
    [ "$usermount" = 1 ] || fail "vfs.usermount is not 1 after the root steps"
    grep -qx 'vfs.usermount=1' /etc/sysctl.conf || fail "/etc/sysctl.conf does not keep vfs.usermount"
    kldstat -q -m fusefs || fail "fusefs is not loaded"
    sysrc -n kld_list | grep -qw fusefs || fail "kld_list does not load fusefs at boot"
    id -Gn "$user_mode_user" | tr ' ' '\n' | grep -qx operator || fail "$user_mode_user is not in the operator group"
    device="$(stat -f '%Sp %Sg' /dev/fuse)"
    [ "$device" = 'crw-rw---- operator' ] ||
        fail "/dev/fuse is not mode 0660 of group operator after the devfs rule"
}

# Starts the documented block as the user, in the background: the client stays in the
# foreground of the block. The password is typed on standard input, as the block says. The
# folder of the work is made enterable, so that the user can read the block.
user_mode_start() {
    start_block="$check_work/user-start.sh"
    user_mode_start_text > "$start_block"
    chmod 711 "$check_work"
    chmod 644 "$start_block"
    printf 'secret\n' | as_user "sh $start_block" > "$check_work/user-client.log" 2>&1 &
    user_client_job=$!
}

# What the client put where the instructions say it does: the user's own folders, and a socket folder
# that only the user may enter.
user_mode_prove_folders() {
    # The user's shell expands HOME, as it does for the user in a terminal.
    # shellcheck disable=SC2016
    home="$(as_user 'echo "$HOME"')"
    uid="$(id -u "$user_mode_user")"
    socket_folder="$(stat -f '%Su %Lp' "/tmp/splicefs-$uid")"
    [ "$socket_folder" = "$user_mode_user 700" ] ||
        fail "/tmp/splicefs-$uid is not owned by $user_mode_user with mode 700"
    [ -f "$home/.config/splicefs/client/clusters.d/example.yaml" ] || fail "the cluster is not in $home/.config/splicefs/client"
    [ -f "$home/.config/splicefs/client/secrets/example" ] || fail "the password is not in $home/.config/splicefs/client"
    # The cache folder is made with the first mount, so what is proved is the place the client chose.
    as_user 'splicefs config show' | grep -qF "$home/.cache/splicefs" || fail "the cache is not in $home/.cache/splicefs"
}

# Opening the device is what a mount does first. It fails for a user who is not in the group
# or when the devfs rule did not apply.
user_mode_prove_device() {
    as_user 'exec 3<>/dev/fuse' || fail "$user_mode_user cannot open /dev/fuse"
}

# Ends the client with the signal the Ctrl-C of the instructions sends, and waits for the block to end, which
# is the signal that the client has stopped.
user_mode_stop() {
    pid="$(pgrep -u "$user_mode_user" -x splicefs)" || fail "no splicefs process of $user_mode_user"
    kill -TERM "$pid" || fail "could not stop the client of $user_mode_user"
    wait "$user_client_job" || true
    if pgrep -u "$user_mode_user" -x splicefs >/dev/null; then fail "the client of $user_mode_user is still running"; fi
    # user_client_answers is one command whose status is the answer, so running it without set -e changes nothing.
    # shellcheck disable=SC2310
    if user_client_answers >/dev/null 2>&1; then fail "the client of $user_mode_user still answers after it was stopped"; fi
}

check_user_mode() {
    user_mode_prepare
    user_mode_start
    wait_for 20 user_client_answers
    # wait_for is the job's, and it sets wait_status.
    # shellcheck disable=SC2154
    if [ "$wait_status" -ne 0 ]; then cat "$check_work/user-client.log"; fail "the client of $user_mode_user does not answer status"; fi
    user_mode_prove_folders
    user_mode_prove_device
    user_mode_stop
    pw userdel -n "$user_mode_user" -r || fail "pw could not remove $user_mode_user"
    echo "user mode: the root steps ran, $user_mode_user started the client, status answered, the folders are $user_mode_user's, /dev/fuse opens, the client stopped"
}
