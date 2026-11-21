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
