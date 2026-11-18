# shellcheck shell=sh
# Serves a folder over local HTTP on a port the system picks, for the tests that stand in for the
# published site (tests/run.sh, scripts/lifecycle-test.sh). Containers reach the server as
# host.docker.internal. Sourced by a script that runs on the host and has python3.
#   start_site_server SITE WORK   starts it; SITE need not exist yet because the server finds its
#                                 files per request; WORK is a folder for its banner and its log.
#                                 Sets site_port.
#   stop_site_server              stops it and waits, so its port is closed when this returns.
site_server_pid=
site_timer_pid=
site_port=

stop_site_server() {
  [ -z "$site_timer_pid" ] || kill "$site_timer_pid" 2>/dev/null || true
  [ -z "$site_server_pid" ] || kill "$site_server_pid" 2>/dev/null || true
  # The server is waited for, so its port is closed and it is gone when this ends.
  [ -z "$site_server_pid" ] || wait "$site_server_pid" 2>/dev/null || true
  site_timer_pid=
  site_server_pid=
}

# Kills the process $1 after a minute. It is a safety stop only: nothing waits for this time
# to pass, the start below waits for the line the server prints. TERM ends it early and takes
# its sleep along.
safety_stop() {
  trap 'kill $!; exit 0' TERM
  sleep 60 &
  wait $!
  kill "$1"
}

# The server prints one line on stdout once its socket is bound, and the port is in that line.
# A pipe carries it, so the read below returns when the line is there, or at end of file when
# the server died first. Nothing else goes to stdout, so no one has to drain the pipe.
start_site_server() {
  mkfifo "$2/banner"
  python3 -u -m http.server 0 --bind 0.0.0.0 --directory "$1" >"$2/banner" 2>"$2/server.log" &
  site_server_pid=$!
  safety_stop "$site_server_pid" >/dev/null 2>&1 &
  site_timer_pid=$!
  exec 3<"$2/banner"
  banner=
  read -r banner <&3 || true
  exec 3<&-
  kill "$site_timer_pid" 2>/dev/null || true
  wait "$site_timer_pid" 2>/dev/null || true
  site_timer_pid=
  case "$banner" in
    "Serving HTTP on "*" port "[0-9]*) ;;
    *) echo "web server did not start" >&2; cat "$2/server.log" >&2; exit 1 ;;
  esac
  site_port=${banner#* port }
  site_port=${site_port%% *}
}
