# shellcheck shell=sh
# What the package test notes and checks about the service of a program across an upgrade
# (scripts/package-test-steps.sh, steps 1a to 4). Sourced after scripts/service-check-lib.sh, the
# service check of the program (scripts/package-test-program-lib.sh) and the functions of the package
# format (scripts/service-test-<format>.sh), which provide fail, must, service_pid, reported_version,
# service_enabled and service_active. $own is the folder of the run's files and $PROGRAM the program,
# as the steps set them. The first argument of every function is the system.
# shellcheck disable=SC2154

# Step 1a ends with the published package's service running. What it is is written down, so that
# step 2 can compare the service after the upgrade with it: its process id and the version its health
# endpoint reports, which must be the published version $2 (v1.2.3).
note_running_service() {
    pid="$(service_pid "$1")" || fail "cannot find the main process of the service"
    reported="$(reported_version "$1")" || fail "the health endpoint of the service does not report a version"
    [ "$reported" = "$2" ] || fail "the service reports $reported, not the published $2"
    printf '%s\n' "$pid" >"$own/running-pid.$PROGRAM"
    printf '%s\n' "$reported" >"$own/running-version.$PROGRAM"
    echo "ok: the service runs as process $pid and reports $reported"
}

# Status 0 when step 1a left the service of the program running, that is when the package of step 2
# goes over a running service.
ran_before_the_package() {
    [ -f "$own/running-pid.$PROGRAM" ]
}

# Step 2, after the new package is installed. A program whose service ran before the package went over
# it must still be enabled and running; otherwise the package itself must not have enabled or started
# anything, because installing is not a decision to run the service.
check_service_after_package() {
    # ran_before_the_package is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if ran_before_the_package; then
        service_enabled "$1" || fail "the service is not enabled after the package was put over it"
        service_active "$1" || fail "the service is not running after the package was put over it"
        echo "ok: installed over a running service, which is still enabled and running"
    else
        check_idle_after_install "$1"
    fi
}

# Step 3 of a program whose service step 1a turned on: the upgrade kept it enabled and its test
# configuration where the documentation says.
check_still_enabled_and_configured() {
    service_enabled "$1" || fail "the service is not enabled: the upgrade turned it off"
    must "the test configuration is not where the documentation says" in_system "$1" check_test_config
    echo "ok: the service is still enabled and its test configuration is where the documentation says"
}

# Step 4 of a program whose service step 1a started: it runs as its own user and does its job.
check_still_running() {
    check_user "$1"
    check_answers "$1"
    echo "ok: the service is still running"
}

# What putting the new package over a running service does, for the package format of the system: the one
# place that says it. Usage: upgrade_effect OLD NEW (the program versions, v1.2.3), prints one of
#   restarts   the package restarts the service itself: deb, rpm and apk always (their scripts run on a
#              reinstall of the same version too: apk add of the file replaces the installed package and runs
#              post-upgrade)
#   keeps      the old process keeps running until the administrator restarts it: pkg on an upgrade, which
#              ends every program a package script starts, so the upgrade message names the restart
#   untouched  the service is not touched at all: pkg on a reinstall of the same version. pkg add -f is a
#              forced install, not an upgrade, and the service keeps its process
upgrade_effect() {
    case "$format:$1" in
        pkg:"$2") echo untouched ;;
        pkg:*) echo keeps ;;
        *) echo restarts ;;
    esac
}

# The message pkg prints when the new package is put over the installed one, for the same arguments as
# upgrade_effect: pkg add -f of the same version is a forced install, which prints the install message,
# not the upgrade message. The other formats print no message, so the answer for them is not looked at.
put_over_message() {
    case "$format:$1" in
        pkg:"$2") echo install ;;
        *) echo upgrade ;;
    esac
}

# The service answers, and runs in a process other than $2, as the version $VERSION. $3 says what
# was done to it, for the messages. The new process id is left in new_pid.
check_new_process_and_version() {
    must "the service is not active and answering 20 seconds after $3" wait_for 20 active_and_answering "$1"
    new_pid="$(service_pid "$1")" || fail "cannot find the main process of the service after $3"
    [ "$new_pid" != "$2" ] || fail "$3 did not start a new process of the service: it still runs as process $2"
    reported="$(reported_version "$1")" || fail "the health endpoint of the service reports no version after $3"
    [ "$reported" = "$VERSION" ] || fail "after $3 the service reports $reported, not the new $VERSION"
}

# The service answers, in the process $2 it ran in before, as the version $3. $4 says what was done to it
# and is not meant to have restarted it, for the messages.
check_same_process_and_version() {
    pid="$(service_pid "$1")" || fail "the service is not running after $4: the old process was meant to keep running"
    [ "$pid" = "$2" ] || fail "$4 restarted the service, which it does not do (process $2, then $pid)"
    reported="$(reported_version "$1")" || fail "the service does not answer after $4"
    [ "$reported" = "$3" ] || fail "after $4 the service reports $reported, not $3"
}

# Step 2, after the new package was put over the service that step 1a started: what the package of the
# format does to it (upgrade_effect). A service the package restarted runs in a new process as the new
# version. On pkg the old process keeps running as the old version until the restart the upgrade message
# names, which is then run, and the service runs the new version. On pkg, for a package of the version
# that is installed, the same process keeps running as the same version. A new process is the
# proof of a restart, so it also shows one when the new package has the published version (a change to the
# packaging alone).
check_upgrade_of_running_service() {
    # ran_before_the_package is one test whose status is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    ran_before_the_package || return 0
    read -r old_pid <"$own/running-pid.$PROGRAM"
    read -r old_version <"$own/running-version.$PROGRAM"
    case "$(upgrade_effect "$old_version" "$VERSION")" in
        restarts)
            check_new_process_and_version "$1" "$old_pid" "the upgrade"
            echo "ok: the package restarted the service (process $old_pid, then $new_pid), which reports $VERSION"
            ;;
        untouched)
            check_same_process_and_version "$1" "$old_pid" "$VERSION" "a reinstall of the same version on $format"
            echo "ok: the service kept running as process $old_pid, which reports $VERSION: a reinstall of the same version leaves it alone on $format"
            ;;
        *)
            check_same_process_and_version "$1" "$old_pid" "$old_version" "the upgrade, before its restart,"
            service_restart "$1" || fail "the restart the upgrade message names failed"
            check_new_process_and_version "$1" "$old_pid" "the restart"
            echo "ok: the old process ($old_pid) kept running as $old_version until the restart, which started process $new_pid as $VERSION"
            ;;
    esac
}
