# shellcheck shell=sh
# answers_text is read by scripts/package-test-steps.sh, which sources this file.
# shellcheck disable=SC2034
# Sourced by scripts/package-test-steps.sh and scripts/service-test-host.sh. It says what "the service
# works" means for this program; everything else in the service test is the same for every program.

# The default listener of the server (docs/configuration.md): every interface, TLS with a
# certificate the server makes for itself. The API lives under the default base path /api
# and the health endpoint is /v1/health (api/routes.go).
port=8480
health_path=/api/v1/health
answers_text="answers 200 on $health_path from inside"

# program and defs are set by scripts/package-lib.sh before it sources this file.
# shellcheck disable=SC2154
expected_user="$(sed -n 's/^User=//p' "$defs/systemd/$program.service")"
[ -n "$expected_user" ] || fail "$defs/systemd/$program.service sets no User"

# Status 0 when the health endpoint answers 200 on the address $1 and port $2. Only the answer
# counts: a port that accepts a connection says nothing about what listens behind it. The
# certificate is not verified: the server made it for itself. Systems differ in what they have to
# talk HTTPS with, so the first of these that exists is used: curl, openssl, wget (busybox, on
# Alpine).
health_answers() {
    if command -v curl >/dev/null 2>&1; then
        code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://$1:$2$health_path" || true)"
        [ "$code" = 200 ]
    elif command -v openssl >/dev/null 2>&1; then
        # HTTP/1.0 makes the server close the connection after the answer, which ends s_client.
        printf 'GET %s HTTP/1.0\r\nHost: %s\r\n\r\n' "$health_path" "$1" |
            timeout 3 openssl s_client -quiet -connect "$1:$2" 2>/dev/null | head -n 1 | grep -q ' 200 '
    else
        wget -q -T 3 -O /dev/null --no-check-certificate "https://$1:$2$health_path" 2>/dev/null
    fi
}

# The same, asked inside the system that runs the service, which the argument names and does not
# need: the server must listen beyond the loopback address, so the request goes to the IPv4 address
# of the system that is not a loopback one, through a real interface and not through lo. Which
# command tells that address differs between systems, so own_address is a function of the adapter of
# the package format (scripts/service-test-<format>.sh).
answers() {
    address="$(own_address)"
    [ -n "$address" ] && health_answers "$address" "$port"
}

# The same on the machine that runs the service itself, where the port is the port it listens on.
answers_here() {
    health_answers 127.0.0.1 "$port"
}
