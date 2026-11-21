# shellcheck shell=sh
# answers_text is read by scripts/package-test.sh, which sources this file.
# shellcheck disable=SC2034
# Sourced by scripts/package-test.sh and scripts/service-test-host.sh. It says what "the service
# works" means for this program; everything else in the service test is the same for every program.

# The default listener of the server (docs/configuration.md): every interface, TLS with a
# certificate the server makes for itself. The API lives under the default base path /api
# and the health endpoint is /v1/health (api/routes.go).
port=8480
health_path=/api/v1/health
answers_text="answers 200 on $health_path from outside"

# program and defs are set by scripts/package-lib.sh before it sources this file.
# shellcheck disable=SC2154
expected_user="$(sed -n 's/^User=//p' "$defs/systemd/$program.service")"
[ -n "$expected_user" ] || fail "$defs/systemd/$program.service sets no User"

# Extra options for docker run: the port is published on a free port of the host.
run_options() {
    printf '%s' "-p 127.0.0.1::$port"
}

# Status 0 when the health endpoint answers 200 on the port $1 of this machine. Only the answer
# counts: Docker accepts the connection on the host even when nothing listens inside.
health_answers() {
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 \
        "https://127.0.0.1:$1$health_path" || true)"
    [ "$code" = 200 ]
}

# The same, asked from the host of the container $1. The published port can change when the
# container restarts, so it is looked up every time.
answers() {
    mapping="$(docker port "$1" "$port/tcp")" || return 1
    hostport="$(printf '%s\n' "$mapping" | head -n 1 | sed 's/.*://')" || return 1
    health_answers "$hostport"
}

# The same on the machine that runs the service itself, where the port is the port it listens on.
answers_here() {
    health_answers "$port"
}
