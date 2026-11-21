# shellcheck shell=sh
# Sourced by scripts/freebsd-job.sh inside the FreeBSD machine. It says what "the service
# works" means for this program; the rest of the job is the same for every SpliceFS program.

# The server sets no expected_user: the package test (scripts/package-test-steps.sh) proves its service
# in full, so the job runs only the checks that test does not make: the install and remove messages and
# the upgrade under a running service. Those start the service and ask it, which is what answers is for.

# Status 0 when the health endpoint answers. The default listener is every interface on
# port 8480, TLS with a certificate the server makes for itself, so the check does not
# verify the certificate.
answers() {
    fetch --no-verify-peer -qo /dev/null https://127.0.0.1:8480/api/v1/health 2>/dev/null
}
