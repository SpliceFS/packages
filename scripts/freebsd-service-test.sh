#!/bin/sh
# check: freebsd-service-test.sh: the FreeBSD packages leave the service off, and tell how to turn it on
# Tests what the FreeBSD packages do about the service, on the host: no machine, no pkg, no
# root (part of make check). The rc scripts run against a stand-in for rc.subr, the install
# scripts of the manifests run with stand-ins for service, sysrc and pw. What rc.subr and pkg
# really do is proved in the machine, by scripts/freebsd-job.sh.
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

# --- the client starts before the late mounts, and only once it answers ---------------------

client_rc=programs/client/freebsd/splicefs.rc

# $1 what is tested, $2 the whole line the script must hold.
holds_line() {
    if grep -qx -e "$2" "$client_rc"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: the line "%s" is missing\n' "$1" "$2"
        failed=$((failed + 1))
    fi
}

# rcorder reads these lines. mountlate runs "mount -a -L", which asks the client for the fstab
# lines marked late, so the client must be started before it; mountlate itself needs DAEMON, which
# the client needs too, so the order is DAEMON, client, mountlate.
holds_line "splicefs: rcorder starts it before mountlate" "# BEFORE: mountlate"
holds_line "splicefs: rcorder starts it after the network, the daemons and the filesystems" \
    "# REQUIRE: NETWORKING DAEMON FILESYSTEMS"
holds_line "splicefs: rc.subr loads the FUSE module before the start" "required_modules=fusefs"
holds_line "splicefs: the start waits for the client to answer" "start_postcmd=splicefs_wait"

# A stand-in for /etc/rc.subr that runs the function named by $entry, with stand-ins for what the
# function calls: timeout runs its command without the time limit, sleep and kill only record
# that they were called, so that no test waits for time to pass. The fake control tool answers
# from its ANSWER_AT-th call on, which is the delay: calls before it fail, as a client does that
# has not connected to its cluster yet.
cat > "$tree/rc-wait.subr" <<'SUBR'
load_rc_config() { :; }
timeout() { shift; "$@"; }
sleep() { echo sleep >> "$box/calls"; }
kill() { echo "kill $*" >> "$box/calls"; }
run_rc_command() { "$entry"; }
SUBR
cat > "$tree/splicefsctl" <<'CTL'
#!/bin/sh
echo ask >> "$box/calls"
[ "$(grep -c ask "$box/calls")" -ge "$ANSWER_AT" ]
CTL
chmod 755 "$tree/splicefsctl"

# Counts the lines of the record that start with $1; grep -c fails when there are none.
recorded() {
    grep -c "^$1" "$box/calls" || true
}

# $1 the number of the call that is answered. Sets wait_result to the exit status of the wait,
# then what was called: the number of asks and of sleeps, and the kills as they were given.
wait_for_client() {
    box="$tree/wait"
    rm -rf "$box"
    mkdir -p "$box"
    : > "$box/calls"
    echo 4242 > "$box/daemon.pid"
    sed -e "s|/etc/rc.subr|$tree/rc-wait.subr|" -e "s|/usr/local/bin/splicefsctl|$tree/splicefsctl|" \
        -e "s|^rundir=.*|rundir=$box|" "$client_rc" > "$tree/rc.script"
    status=0
    box="$box" entry=splicefs_wait ANSWER_AT="$1" sh "$tree/rc.script" start > "$box/out" 2>&1 || status=$?
    asked="$(recorded ask)"
    slept="$(recorded sleep)"
    killed="$(grep '^kill' "$box/calls" | tr '\n' ';')" || killed=""
    wait_result="$status asks=$asked sleeps=$slept $killed"
}

# Before the first answer the start does not return: it asks again each second.
wait_for_client 1
same "splicefs: the start returns at the first answer, without waiting" "0 asks=1 sleeps=0 " "$wait_result"
wait_for_client 3
same "splicefs: the start returns only after the answer that comes late" "0 asks=3 sleeps=2 " "$wait_result"
wait_for_client 31
same "splicefs: a client that never answers fails the start after 30 tries and ends the supervisor" \
    "1 asks=30 sleeps=29 kill 4242;" "$wait_result"
said="$(cat "$box/out")"
holds "splicefs: a start that fails says why" "does not answer" "$said"

# --- stopping leaves no run folder ----------------------------------------------------------

# The run folder holds the pid files and, for the client, the control socket. rc.subr runs the
# function that stop_postcmd names once the service has stopped, and that function takes the folder
# away, so that a stopped service leaves nothing in /var/run. $1 the program, $2 its service. Runs
# that function in a run folder of the test that holds what the service puts there, and sets
# stop_status to its exit status and stop_left to what is left of the folder.
run_stop_postcmd() {
    box="$tree/stop-$2"
    rm -rf "$box"
    mkdir -p "$box/run"
    : > "$box/run/daemon.pid"
    : > "$box/run/$2.pid"
    rc_file="programs/$1/freebsd/$2.rc"
    function_name="$(sed -n 's/^stop_postcmd=//p' "$rc_file")"
    sed -e "s|/etc/rc.subr|$tree/rc-wait.subr|" -e "s|^rundir=.*|rundir=$box/run|" "$rc_file" > "$tree/rc.script"
    stop_status=0
    box="$box" entry="$function_name" sh "$tree/rc.script" stop > "$box/out" 2>&1 || stop_status=$?
    stop_left="$(ls -A "$box")"
}

while read -r program service; do
    run_stop_postcmd "$program" "$service"
    same "$service: the function that stop_postcmd names succeeds" 0 "$stop_status"
    same "$service: stopping takes the run folder away" "out" "$stop_left"
done <<PROGRAMS
$programs
PROGRAMS

# --- the checks that the machine runs for the client ----------------------------------------

# check-lib.sh runs in the machine with the real rcorder and mount. Here stand-ins show that its
# checks tell a good boot order and a late line that reaches the helper from a bad one. $1 the
# order rcorder prints (names of scripts, one to a line), $2 what the stand-in mount does for a
# late line ("helper" prints the helper's refusal and, as mount(8) does, fails unless the line
# says failok; "nofailok" fails even then; "mounted" succeeds without the helper) and for a plain
# mount -a ("skipped" prints nothing, "ran" runs the late line). Sets
# machine_status to the status of the checks and machine_said to what they said.
machine_checks() {
    box="$tree/machine"
    rm -rf "$box"
    mkdir -p "$box/bin"
    printf '/usr/local/sbin/mount.splicefs /usr/local/bin/splicefsctl\n' > "$box/links"
    printf '%s\n' "$1" > "$box/rcorder.out"
    printf '#!/bin/sh\ncat "%s/rcorder.out"\n' "$box" > "$box/bin/rcorder"
    cat > "$box/bin/mount" <<'MOUNT'
#!/bin/sh
case " $* " in
    *" -L "*) [ "$MOUNT_LATE" = mounted ] && exit 0
              echo "mount.splicefs: cluster nocluster is not defined" >&2
              fstab="$(printf '%s\n' "$@" | awk 'f { print; exit } $0 == "-F" { f = 1 }')"
              [ "$MOUNT_LATE" = helper ] && grep -q ',failok,' "$fstab" && exit 0
              exit 1 ;;
    "  ") exit 0 ;;
    *) [ "$MOUNT_PLAIN" = ran ] && echo "mount.splicefs: cluster nocluster is not defined" >&2
       exit 0 ;;
esac
MOUNT
    chmod 755 "$box/bin/rcorder" "$box/bin/mount"
    cat > "$box/run.sh" <<'RUN'
fail() { echo "FAIL: $1"; exit 1; }
. "$1"
# The user mode check has a test of its own, below; here it only has to be called.
check_user_mode() { echo "user mode check ran"; }
extra_checks
RUN
    status=0
    machine_said="$(in="$box" PATH="$box/bin:$PATH" MOUNT_LATE="$2" MOUNT_PLAIN="$3" \
        sh "$box/run.sh" "$root/programs/client/freebsd/check-lib.sh" 2>&1)" || status=$?
    machine_status="$status"
}

good_order='/etc/rc.d/DAEMON
/usr/local/etc/rc.d/splicefs
/etc/rc.d/mountlate'
machine_checks "$good_order" helper skipped
same "the machine accepts splicefs before mountlate, and a late line that reaches the helper" \
    "0" "$machine_status"
holds "the machine says that the order is right" "rcorder: splicefs starts before mountlate" "$machine_said"
holds "the machine runs the user mode check after the boot checks" "user mode check ran" "$machine_said"
holds "the machine says that the late line reached the helper" "the late line ran the helper" "$machine_said"
machine_checks '/etc/rc.d/mountlate
/usr/local/etc/rc.d/splicefs' helper skipped
holds "the machine refuses mountlate before splicefs" "FAIL: rcorder starts mountlate" "$machine_said"
machine_checks '/etc/rc.d/mountlate' helper skipped
holds "the machine refuses an rcorder list without splicefs" "FAIL: rcorder does not list" "$machine_said"
machine_checks "$good_order" nofailok skipped
holds "the machine refuses a late line whose failure would stop the boot" \
    "FAIL: mount -a -L failed for a failok line" "$machine_said"
machine_checks "$good_order" mounted skipped
holds "the machine refuses a late line that did not reach the helper" \
    "FAIL: mount -a -L did not run the helper" "$machine_said"
machine_checks "$good_order" helper ran
holds "the machine refuses a plain mount -a that runs a late line" "FAIL: mount -a ran the late line" \
    "$machine_said"

# --- the user mode check of the machine -----------------------------------------------------

# check_user_mode of check-lib.sh runs the steps of "Run as yourself" in the machine: the
# one-time steps as root, then the client as an ordinary user. Here stand-ins show that it tells
# a machine where all of it works from one where a part does not. The machine's own tools are
# stand-ins; only the files the steps write under /etc and the file /dev/fuse are moved into a
# folder of the test. What the real tools do is proved in the machine.
#   um_fail        the tools that fail, by name ("" for none)
#   um_client      "ready" for a client that answers, "dead" for one that stops at once
#   um_socket      the owner and mode the client's socket folder has
#   um_fuse_stat   the mode and group of /dev/fuse after the devfs rule
#   um_fuse        "file" for a /dev/fuse that opens, "dir" for one that cannot be opened
#   um_cache       "home" when the client puts its cache in the user's home, else "root"
# user_mode_machine sets user_mode_status and user_mode_said, and puts the settings back.
um_fail='' um_client=ready um_socket='alice 700' um_fuse_stat='crw-rw---- operator' um_fuse=file um_cache=home

# Writes the stand-ins of the tools into the folder $1, except the client and its control program,
# which go into $2, the /usr/local/bin of the machine: the PATH of root does not hold it, and the
# PATH of the user must. The tools that are only called share one
# script, which records the call, fails when it is named in FAIL_TOOL, and prints what the check
# asks of the few that answer. The client stand-in tells the control stand-in over a FIFO whether
# it is ready: the first status waits for that word, so that no step waits for time to pass.
write_user_mode_tools() {
    cat > "$1/standin" <<'STANDIN'
#!/bin/sh
name="$(basename "$0")"
echo "$name $*" >> "$box/calls"
case " $FAIL_TOOL " in *" $name "*) exit 1 ;; esac
case "$name $*" in
    "sysctl -n vfs.usermount") echo 1 ;;
    "sysrc -n kld_list") echo fusefs ;;
    "id -u"*) echo 4242 ;;
    "id -Gn"*) echo "alice operator" ;;
    "pw useradd"*) mkdir -p "$box/home/$2" ;;
    "pw userdel"*) rm -rf "$box/home/alice" ;;
esac
STANDIN
    for tool in pw sysctl sysrc kldload kldstat service id; do ln -s standin "$1/$tool"; done
    cat > "$1/su" <<'SU'
#!/bin/sh
# su [-l] USER -c COMMAND: the command runs with the home folder su sets and the PATH of the caller,
# as the su of FreeBSD does without -l. A login shell reads the profile of the user, and the profile
# that FreeBSD gives a new user prints a fortune, so the output of a command run in a login starts
# with a line that is not the command's.
login=no
if [ "$1" = -l ]; then login=yes; shift; fi
[ "$2" = -c ] || exit 2
[ "$login" = no ] || echo 'If you do not want to get beeps in X11 (X Windows), you can turn them off with'
exec env HOME="$box/home/$1" sh -c "$3"
SU
    cat > "$1/stat" <<'STAT'
#!/bin/sh
for path; do :; done
case "$path" in
    */fuse) echo "$FUSE_STAT" ;;
    *) cat "$box/stat/$(basename "$path")" ;;
esac
STAT
    cat > "$1/pgrep" <<'PGREP'
#!/bin/sh
[ -f "$box/client.pid" ] && cat "$box/client.pid"
PGREP
    cat > "$2/splicefsctl" <<'CTL'
#!/bin/sh
[ -f "$box/state" ] || { read -r word < "$box/state.fifo"; echo "$word" > "$box/state"; }
[ "$(cat "$box/state")" = ready ]
CTL
    cat > "$2/splicefs" <<'CLIENT'
#!/bin/sh
if [ "$1" = config ]; then
    dir="$HOME/.cache/splicefs"
    [ "$CACHE" != root ] || dir=/var/cache/splicefs
    printf 'cache:\n  dir: %s\n' "$dir"
    exit 0
fi
echo "$$" > "$box/client.pid"
echo "$SOCKET_STAT" > "$box/stat/splicefs-4242"
if [ "$CLIENT" != ready ]; then
    rm -f "$box/client.pid"
    echo dead > "$box/state.fifo"
    exit 1
fi
# This process lives until the check ends it with the stop signal.
sleep 600 &
sleeper=$!
trap 'rm -f "$box/client.pid"; echo stopped > "$box/state"; kill "$sleeper"; exit 0' TERM
echo ready > "$box/state.fifo"
wait "$sleeper"
CLIENT
    chmod 755 "$1/standin" "$1/su" "$1/stat" "$1/pgrep" "$2/splicefsctl" "$2/splicefs"
}

# Ends the process $1 and returns once it is gone; a process that already ended is fine. Gives up
# after 100 looks and counts that as a failure.
end_left_over() {
    kill "$1" 2>/dev/null || :
    looks=0
    while kill -0 "$1" 2>/dev/null; do
        looks=$((looks + 1))
        if [ "$looks" -gt 100 ]; then
            printf 'FAIL the left-over client %s did not end\n' "$1"
            failed=$((failed + 1))
            return
        fi
        sleep 0.1
    done
}

user_mode_machine() {
    box="$tree/user"
    rm -rf "$box"
    mkdir -p "$box/bin" "$box/usr/local/bin" "$box/etc" "$box/dev" "$box/work" "$box/stat"
    mkfifo "$box/state.fifo"
    : > "$box/calls"
    write_user_mode_tools "$box/bin" "$box/usr/local/bin"
    if [ "$um_fuse" = dir ]; then mkdir "$box/dev/fuse"; else : > "$box/dev/fuse"; fi
    # The steps append to files of /etc, the check opens /dev/fuse, and the PATH of the user names
    # /usr/local/bin: all three move into the folder.
    sed -e "s| /etc/| $box/etc/|g" -e "s|/dev/fuse|$box/dev/fuse|g" -e "s|/usr/local/bin|$box/usr/local/bin|g" \
        "$root/programs/client/freebsd/check-lib.sh" > "$box/check-lib.sh"
    cat > "$box/run.sh" <<'RUN'
fail() { echo "FAIL: $1"; exit 1; }
# The control stand-in waits for the client, so one try is a whole wait.
wait_for() { shift; wait_status=0; "$@" >/dev/null 2>&1 || wait_status=1; }
. "$1"
check_work="$box/work"
check_user_mode
RUN
    # The output goes to a file, not to a pipe of $(...): a check that failed with the client
    # running leaves the client (and its sleep) holding the output open, and $(...) would wait for
    # them while they wait to be ended below.
    status=0
    # The root of the machine has no XDG settings, and the stand-in su leaves the environment as it is.
    env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME box="$box" PATH="$box/bin:$PATH" FAIL_TOOL="$um_fail" CLIENT="$um_client" \
        SOCKET_STAT="$um_socket" FUSE_STAT="$um_fuse_stat" CACHE="$um_cache" \
        sh "$box/run.sh" "$box/check-lib.sh" > "$box/said" 2>&1 < /dev/null || status=$?
    user_mode_status="$status"
    # Ending a left-over client is part of the test. It is not a child of this shell, so its end is
    # seen by asking for the process; the next case starts only after it is gone, because its last
    # act is a write into the folder that the next case makes again.
    if [ -f "$box/client.pid" ]; then
        left_over="$(cat "$box/client.pid")"
        end_left_over "$left_over"
    fi
    user_mode_said="$(cat "$box/said")"
    um_fail='' um_client=ready um_socket='alice 700' um_fuse_stat='crw-rw---- operator' um_fuse=file um_cache=home
}

user_mode_machine
same "the machine accepts a user who runs the client as the README shows" 0 "$user_mode_status"
holds "the machine says that the user mode works" "user mode:" "$user_mode_said"
calls="$(cat "$box/calls")"
holds "the machine removed the user it made" "pw userdel" "$calls"
if [ -e "$box/client.pid" ]; then
    printf 'FAIL the machine left the client running\n'
    failed=$((failed + 1))
else
    printf 'ok   the machine stopped the client\n'
fi

um_fail=sysctl
user_mode_machine
holds "the machine refuses a root step that fails" \
    "FAIL: the documented step failed: sysctl vfs.usermount=1" "$user_mode_said"
um_fail=kldload
user_mode_machine
holds "the machine refuses a root step that fails, whichever it is" \
    "FAIL: the documented step failed: sysrc kld_list+=fusefs && kldload -n fusefs" "$user_mode_said"
um_fail=kldstat
user_mode_machine
holds "the machine refuses a machine where fusefs is not loaded" "FAIL: fusefs is not loaded" "$user_mode_said"
um_fuse_stat='crw------- root'
user_mode_machine
holds "the machine refuses a /dev/fuse that the devfs rule did not open to the group" \
    "mode 0660 of group operator" "$user_mode_said"
um_client=dead
user_mode_machine
holds "the machine refuses a client that does not answer the user" "does not answer" "$user_mode_said"
um_socket='alice 755'
user_mode_machine
holds "the machine refuses a socket folder that others may enter" \
    "is not owned by alice with mode 700" "$user_mode_said"
um_socket='root 700'
user_mode_machine
holds "the machine refuses a socket folder of another owner" \
    "is not owned by alice with mode 700" "$user_mode_said"
um_cache=root
user_mode_machine
holds "the machine refuses a cache outside the user's home" "the cache is not in" "$user_mode_said"
um_fuse=dir
user_mode_machine
holds "the machine refuses a /dev/fuse that the user cannot open" "cannot open" "$user_mode_said"

# The root steps live only in check-lib.sh (the install page, which shows them, is the website's);
# the start block is the file steps/user-mode-start.sh.
check_lib=programs/client/freebsd/check-lib.sh
# Prints the lines of check-lib.sh inside the here-document that ends in the word $1.
check_lib_text() {
    awk -v word="$1" '$0 == word { reading = 0 } reading { print } index($0, "<<\047" word "\047") { reading = 1 }' "$check_lib"
}
# An empty list would pass every comparison below.
root_steps="$(check_lib_text ROOT_STEPS)"
start_steps="$(check_lib_text START_STEPS)"
step_count="$(printf '%s\n' "$root_steps" | awk 'END { print NR }')"
same "check-lib.sh holds the six root steps" 6 "$step_count"
documented_start="$(cat steps/user-mode-start.sh)"
same "the start block of check-lib.sh is steps/user-mode-start.sh" "$documented_start" "$start_steps"

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
    holds "$service: the remove message says the setting is deleted only if the service was turned on" \
        "If you turned the service on, delete its setting:" "$text"
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
