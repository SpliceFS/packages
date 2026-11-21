#!/bin/sh
# check: package-test.sh: the host boots each system, runs the three phases with the restart between them, asks the server from a probe container after phases 1 and 2, collects the output and names the failed step
# Test of scripts/package-test.sh, the host's part of the package test, with a stand-in docker command,
# so it needs no Docker and no network. The stand-in writes every call to a log and answers like a
# container that runs the steps: the phase of the steps that is run writes the log and the result
# the case says into the folder of the container, which docker cp copies out. The probe container that
# asks the server from outside answers with the HTTP status the case says for the time before and after
# the restart of the container. A call that holds the
# text in STAND_IN_FAIL fails. The package site is a stand-in curl, and the proof of a download a
# stand-in published-verify.sh, which fails when the file is named in STAND_IN_UNPROVEN. The steps
# themselves are tested in scripts/package-test-steps-test.sh.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failed=0

# The repository as the script sees it, made once: the real scripts and definitions, apart from the
# proof of a download, which needs the network and gpg, and the list of systems, which has two of
# the format deb here. Every case gets its own folder of links to it and its own record of a build,
# so that the cases run at the same time.
mkdir -p "$t/farm/scripts" "$t/farm/packaging" "$t/bin"
ln -s "$root/programs" "$t/farm/programs"
ln -s "$root/steps" "$t/farm/steps"
ln -s "$root/keys" "$t/farm/keys"
for each in "$root"/scripts/* "$root"/packaging/*; do
    ln -s "$each" "$t/farm/${each#"$root"/}"
done
rm "$t/farm/scripts/published-verify.sh" "$t/farm/packaging/test-systems"
cat >"$t/farm/scripts/published-verify.sh" <<'STAND_IN'
#!/bin/sh
# Stand-in for the proof of a download: says what it was asked and fails for a named file.
echo "verify $*" >>"$STAND_IN_DIR/log"
[ -z "${STAND_IN_UNPROVEN:-}" ] || case "$1" in *"$STAND_IN_UNPROVEN"*) exit 1 ;; *) ;; esac
STAND_IN
chmod 755 "$t/farm/scripts/published-verify.sh"
printf 'deb ghcr.io/splicefs/server-debian-12:v1.0\ndeb ghcr.io/splicefs/server-ubuntu-24.04:v1.0\n' \
    >"$t/farm/packaging/test-systems"
printf 'rpm ghcr.io/splicefs/server-rocky-9:v1.0\napk ghcr.io/splicefs/server-alpine-3.22:v1.0\n' \
    >>"$t/farm/packaging/test-systems"
cat >"$t/bin/curl" <<'STAND_IN'
#!/bin/sh
# Stand-in curl: every address is logged and writes a file for the output name. The site serves the
# keys of the repository, or another key when STAND_IN_OTHER_KEY is set.
echo "curl $*" >>"$STAND_IN_DIR/log"
[ -z "${STAND_IN_NO_SITE:-}" ] || exit 22
for url; do :; done
while [ "$#" -gt 0 ]; do
    case "$1:$url" in
        -o:*/keys/*) if [ -n "${STAND_IN_OTHER_KEY:-}" ]; then echo other >"$2"; else cp "$STAND_IN_KEYS/${url##*/}" "$2"; fi ;;
        -o:*) echo published >"$2" ;;
        *) ;;
    esac
    shift
done
STAND_IN
chmod 755 "$t/bin/curl"

cat >"$t/bin/docker" <<'STAND_IN'
#!/bin/sh
# Stand-in docker. STAND_IN_DIR holds the log of the calls and, for each container, a folder named
# by it that stands for the folder the steps write into. A phase of the steps run in a container
# appends one line to its log, and writes its result in the third phase or when it fails:
# STAND_IN_RESULT is the line of the step that fails, which is also the status of the phase (set
# for the phase named in STAND_IN_FAILED_PHASE), and "ok" otherwise; STAND_IN_NO_RESULT writes none.
# A system is named in the call by its container, so that the systems of one case, which run at the
# same time, do not share what the stand-in remembers.
echo "docker $*" >>"$STAND_IN_DIR/log"
call="$*"
rest="${call#*splicefs-package-test-}"
container="splicefs-package-test-${rest%% *}"
container="${container%%:*}"
folder="$STAND_IN_DIR/out.$container"
if [ -n "${STAND_IN_FAIL:-}" ]; then
    case "$call" in *"$STAND_IN_FAIL"*) exit 1 ;; *) ;; esac
fi
case "$1" in
    version) echo linux/amd64 ;;
    inspect)
        # The address of the system on its network, or whether it runs.
        case "$call" in *IPAddress*) echo "bridge 172.17.0.2" ;; *) echo true ;; esac
        ;;
    run)
        case "$call" in
            *":/src:ro"*)
                # The boot: what is mounted at /src has what the steps read at the moment the system starts.
                src="${call%%:/src:ro*}"
                src="${src##* }"
                for read_file in scripts/package-test-steps.sh scripts/service-run-local.sh dist/server/version; do
                    [ ! -f "$src/$read_file" ] || echo "the folder at /src has $read_file" >>"$STAND_IN_DIR/log"
                done
                echo "the folder at /src is $src" >>"$STAND_IN_DIR/log"
                ;;
            # The probe container, which asks the server from the network of the system.
            *"go:v1 curl"*)
                if grep -q 'package-test-steps.sh phase2' "$STAND_IN_DIR/log"; then
                    printf '%s' "${STAND_IN_OUTSIDE_AFTER_2:-200}"
                else
                    printf '%s' "${STAND_IN_OUTSIDE_AFTER_1:-200}"
                fi
                ;;
            *) ;;
        esac
        ;;
    logs) echo "container output" ;;
    cp)
        # docker cp CONTAINER:/folder/. DESTINATION
        [ -d "$folder" ] || exit 1
        cp -R "$folder/." "$3"
        ;;
    exec)
        case "$call" in
            *is-system-running*) echo running ;;
            *"package-test-steps.sh phase1"*)
                mkdir -p "$folder"
                echo "the log of phase 1" >>"$folder/log"
                if [ "${STAND_IN_FAILED_PHASE:-}" = phase1 ]; then
                    [ -n "${STAND_IN_NO_RESULT:-}" ] || echo "${STAND_IN_RESULT:-}" >"$folder/result"
                    exit 1
                fi
                ;;
            *"package-test-steps.sh phase2"*)
                mkdir -p "$folder"
                echo "the log of phase 2" >>"$folder/log"
                if [ "${STAND_IN_FAILED_PHASE:-}" = phase2 ]; then
                    [ -n "${STAND_IN_NO_RESULT:-}" ] || echo "${STAND_IN_RESULT:-}" >"$folder/result"
                    exit 1
                fi
                ;;
            *"package-test-steps.sh phase3"*)
                mkdir -p "$folder"
                echo "the log of phase 3" >>"$folder/log"
                if [ "${STAND_IN_FAILED_PHASE:-}" = phase3 ]; then
                    [ -n "${STAND_IN_NO_RESULT:-}" ] || echo "${STAND_IN_RESULT:-}" >"$folder/result"
                    exit 1
                fi
                [ -n "${STAND_IN_NO_RESULT:-}" ] || echo ok >"$folder/result"
                ;;
            *) ;;
        esac
        ;;
    *) ;;
esac
STAND_IN
chmod 755 "$t/bin/docker"

# What every case starts from: only the server is built (v1.2.3, and its record names 1.2.2 as the
# published version; the client is v1.4.0 and its record names 1.3.9), no call fails, every phase
# passes, and the systems of the list are all tested.
scenario() {
    built="server"
    empty_client=
    record=1.2.2
    fail_on=
    unproven=
    no_site=
    other_key=
    failed_phase=
    result=
    no_result=
    target=
    outside_after_1=200
    outside_after_2=200
}

# Starts the case $1 in the background with the settings of scenario: $built names the programs whose
# packages are in dist ($empty_client makes a folder of the client with nothing in it), $target is the
# image or format of the systems to test. A call that holds the text in $fail_on fails. $failed_phase
# names the phase (phase1, phase2 or phase3) that fails, with $result as the line of the step it failed
# in. $outside_after_1 and $outside_after_2 are the HTTP status the probe container gets from the
# server after phase 1 and after phase 2.
# Keeps the output in $t/cases/$1/out, the calls in $t/cases/$1/dir/log and the status in
# $t/cases/$1/status; the cases are read with use_case, after wait.
launch() {
    case_dir="$t/cases/$1"
    mkdir -p "$case_dir/dir" "$case_dir/root/dist"
    for each in scripts packaging programs steps keys; do ln -s "$t/farm/$each" "$case_dir/root/$each"; done
    for program in $built; do
        mkdir -p "$case_dir/root/dist/$program"
        case "$program" in
            server) printf 'VERSION=v1.2.3\nPACKAGE_DATE=20261112\nUPGRADE_FROM=%s\n' "$record" ;;
            *) printf 'VERSION=v1.4.0\nPACKAGE_DATE=20261113\nUPGRADE_FROM=1.3.9\n' ;;
        esac >"$case_dir/root/dist/$program/version"
    done
    [ -z "$empty_client" ] || mkdir "$case_dir/root/dist/client"
    (
        status=0
        STAND_IN_FAIL="$fail_on" STAND_IN_DIR="$case_dir/dir" PATH="$t/bin:$PATH" ONLY="$target" \
            STAND_IN_UNPROVEN="$unproven" STAND_IN_NO_SITE="$no_site" STAND_IN_KEYS="$root/keys" \
            STAND_IN_OTHER_KEY="$other_key" STAND_IN_FAILED_PHASE="$failed_phase" STAND_IN_RESULT="$result" \
            STAND_IN_NO_RESULT="$no_result" STAND_IN_OUTSIDE_AFTER_1="$outside_after_1" \
            STAND_IN_OUTSIDE_AFTER_2="$outside_after_2" GO_IMAGE=ghcr.io/splicefs/go:v1 \
            sh "$case_dir/root/scripts/package-test.sh" >"$case_dir/out" 2>&1 || status=$?
        echo "$status" >"$case_dir/status"
    ) &
}

# Points the checks that follow at the case $1: $out, $dir and $status.
use_case() {
    out="$t/cases/$1/out"
    dir="$t/cases/$1/dir"
    read -r status <"$t/cases/$1/status"
}

# The line number of the first call in the log that holds the text $1, or 0.
line_of() {
    n="$(grep -n -F -e "$1" "$dir/log" | head -n 1 | cut -d: -f1)"
    echo "${n:-0}"
}

# The name of the case, then the command that must succeed; the output is shown when it does not.
expect() {
    name="$1"
    shift
    if "$@"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        sed 's/^/     /' "$out"
        failed=$((failed + 1))
    fi
}

holds() { grep -q -F -e "$1" "$out"; }
# The calls of the phases, the restarts, the probes and the first boot, in the order they were made, as
# one line.
sequence_is() {
    grep -o -e 'docker run -d' -e 'package-test-steps.sh phase[123]' -e 'docker restart' -e 'go:v1 curl' -e 'docker cp' "$dir/log" |
        tr '\n' ',' >"$dir/sequence"
    printf '%s' "$1" | cmp -s - "$dir/sequence"
}
lacks() { ! grep -q -F -e "$1" "$out"; }
# The calls named by the arguments are in the log, in that order.
in_order() {
    previous=0
    for call in "$@"; do
        n="$(line_of "$call")"
        [ "$n" -gt "$previous" ] || return 1
        previous="$n"
    done
}
failed_status() { [ "$status" -ne 0 ]; }
passed_status() { [ "$status" -eq 0 ]; }
no_call() { ! grep -q -F -e "$1" "$dir/log"; }
calls_of() { grep -c -F -e "$1" "$dir/log" || true; }

debian=ghcr.io/splicefs/server-debian-12:v1.0
old_file=apt/pool/main/s/splicefs-server/splicefs-server_1.2.2_amd64.deb

# Every case runs at the same time, because each is a process that starts a few hundred more.
scenario; target=$debian; launch good
scenario; target=deb; launch two_systems
scenario; target=$debian; record=none; launch nothing_published
scenario; target=$debian; no_site=1; launch no_site
scenario; target=$debian; unproven=.deb; launch unproven
scenario; target=$debian; other_key=1; launch other_key
scenario; target=$debian; failed_phase=phase1; result="step 4: server: the service is started"; launch phase1_fails
scenario; target=$debian; failed_phase=phase2; result="step 5: server: the service is active again"; launch phase2_fails
scenario; target=$debian; failed_phase=phase3; result="step 9: the system is as it was"; launch phase3_fails
scenario; target=$debian; outside_after_1=000; launch outside_fails_after_1
scenario; target=$debian; outside_after_2=000; launch outside_fails_after_2
scenario; target=$debian; outside_after_2=503; launch outside_wrong_status
scenario; target=$debian; built="server client"; outside_after_1=000; launch both_outside_fails
scenario; target=$debian; fail_on="restart splicefs-package-test"; launch restart_fails
scenario; target=$debian; failed_phase=phase3; no_result=1; launch no_result
scenario; target=deb; fail_on="-2 sh scripts/package-test-steps.sh phase1"; launch one_of_two_fails
scenario; target=$debian; built=client; launch client_only
scenario; target=$debian; built="server client"; launch both
scenario; target=$debian; built=; launch none
scenario; target=$debian; empty_client=1; launch empty_client_folder
wait

use_case good
expect "a good run passes" passed_status
expect "the system is named as passed" holds "ok   deb $debian"
expect "the system is booted once" sh -c "[ \"\$(grep -c 'docker run -d' '$dir/log')\" -eq 1 ]"
expect "a copy of the repository is mounted read only at /src, so that a change of the repository during the run is not seen by the system" \
    sh -c "grep -q 'docker run.* -v .*/repository:/src:ro' '$dir/log' && ! grep -q 'the folder at /src is $t/cases/good/root' '$dir/log'"
expect "the copy has the steps, the way to run commands in the system and the record of the build when the system starts" \
    sh -c "grep -q 'the folder at /src has scripts/package-test-steps.sh' '$dir/log' && grep -q 'the folder at /src has scripts/service-run-local.sh' '$dir/log' && grep -q 'the folder at /src has dist/server/version' '$dir/log'"
expect "the keys of the site are mounted read only at /keys" sh -c "grep -q 'docker run.* -v .*/keys:/keys:ro' '$dir/log'"
expect "the baselines are mounted read only at /baselines" sh -c "grep -q 'docker run.* -v .*/baselines:/baselines:ro' '$dir/log'"
expect "the package folder of the program is mounted at /pkg/PROGRAM" \
    sh -c "grep -q 'docker run.* -v $t/cases/good/root/dist/server:/pkg/server:ro' '$dir/log'"
expect "no port is published: the probe container asks from the network of the system" sh -c "! grep -q 'docker run.* -p ' '$dir/log'"
expect "phase 1, the probe, the restart of the container, phase 2, the probe, phase 3, in this order" \
    sequence_is "docker run -d,package-test-steps.sh phase1,go:v1 curl,docker restart,package-test-steps.sh phase2,go:v1 curl,package-test-steps.sh phase3,docker cp,"
expect "the probe container is the project's Go image, on the network of the system, and goes away" \
    sh -c "grep -q 'docker run --rm --network bridge ghcr.io/splicefs/go:v1 curl' '$dir/log'"
expect "the probe asks the health endpoint at the address of the system and the port of the server" \
    sh -c "[ \"\$(grep -c 'https://172.17.0.2:8480/api/v1/health' '$dir/log')\" -eq 2 ]"
expect "the address is read again after the restart, which can change it" \
    sh -c "[ \"\$(grep -c 'docker inspect.*IPAddress' '$dir/log')\" -eq 2 ]"
expect "the answer is said to be from outside, after each phase that asks" \
    sh -c "grep -q 'answers 200 on /api/v1/health from outside, after phase 1' '$out' && grep -q 'answers 200 on /api/v1/health from outside, after phase 2' '$out'"
expect "the service manager is waited for before the first phase and after the restart" \
    sh -c "[ \"\$(grep -c 'is-system-running' '$dir/log')\" -eq 2 ]"
expect "the steps are told the format, the platform, the programs and the folder of their output" \
    sh -c "grep -q 'phase1' '$dir/log' && grep -q -e '-e FORMAT=deb -e PLATFORM=linux/amd64 -e PROGRAMS=server -e PACKAGE_TEST_OUT=/var/tmp/package-test' '$dir/log'"
expect "the steps run in the repository at /src" sh -c "grep -q -e '-w /src splicefs-package-test-.* sh scripts/package-test-steps.sh phase1' '$dir/log'"
expect "the log of the three phases is printed, in order" \
    sh -c "grep -n 'the log of phase' '$out' | cut -d: -f2 | tr '\n' '|' | grep -q 'the log of phase 1|the log of phase 2|the log of phase 3|'"
expect "the output folder is copied out of the container" sh -c "grep -q 'docker cp splicefs-package-test-.*:/var/tmp/package-test/\\.' '$dir/log'"
expect "the container is removed" sh -c "grep -q 'docker rm -f splicefs-package-test-' '$dir/log'"
expect "the signing keys are fetched from the site once, and the package files after them" \
    sh -c "[ \"\$(grep -c 'curl.*/keys/splicefs.asc' '$dir/log')\" -eq 1 ] && [ \"\$(grep -c 'curl.*/keys/splicefs.rsa.pub' '$dir/log')\" -eq 1 ]"
expect "the published package file is fetched from the site and proven by the signed index" \
    sh -c "grep -q 'curl.*/server/$old_file' '$dir/log' && grep -q 'verify $old_file ' '$dir/log'"
expect "the version of the baseline is given to the system in a file" \
    sh -c "grep -q 'docker run.* -v $t/cases/good/baselines' '$dir/log' || grep -q 'docker run.* -v .*/baselines:/baselines:ro' '$dir/log'"
expect "a program with packages is not said to be left out" lacks "server: no packages"
expect "a program with no packages is left out, and said" holds "client: no packages, left out"
expect "no folder of a program with no packages is mounted" sh -c "! grep -q 'dist/client' '$dir/log'"

use_case two_systems
expect "two systems of one format pass" holds "passed: 2  failed: 0"
expect "the published file of a format is fetched once for all its systems" \
    sh -c "[ \"\$(grep -c 'curl.*/server/$old_file' '$dir/log')\" -eq 1 ] && [ \"\$(grep -c 'verify $old_file ' '$dir/log')\" -eq 1 ]"
expect "each system is a container of its own" sh -c "[ \"\$(grep -c 'docker run -d' '$dir/log')\" -eq 2 ]"

use_case nothing_published
expect "a run with nothing published passes" passed_status
expect "nothing is fetched or proven" sh -c "! grep -q '^curl\|^verify ' '$dir/log'"

use_case other_key
expect "a signing key on the site that is not the repository's key fails the run" failed_status
expect "the keys are named" holds "could not download and verify the signing keys"
expect "no system is started when the keys do not prove" no_call "docker run"

use_case no_site
expect "a download that fails fails the run" failed_status
expect "the failed download is named" holds "could not download and verify"
expect "no system is started when the download failed" no_call "docker run"

use_case unproven
expect "a file that does not prove fails the run" failed_status
expect "the file that does not prove is named" holds "could not download and verify"

use_case phase1_fails
expect "a failing phase 1 fails the system" failed_status
expect "the failing step is named with its number" holds "FAIL deb $debian (step 4)"
expect "the line of the failing step is shown" holds "     step 4: server: the service is started"
expect "the log of the phase that failed is printed" holds "the log of phase 1"
expect "the container is not restarted" no_call "docker restart"
expect "phase 2 does not run" no_call "package-test-steps.sh phase2"
expect "the output is collected all the same" sh -c "grep -q 'docker cp' '$dir/log'"

use_case phase2_fails
expect "a failing phase 2 fails the system" failed_status
expect "the failing step is named with its number" holds "FAIL deb $debian (step 5)"
expect "the logs of both phases are printed" sh -c "grep -q 'the log of phase 1' '$out' && grep -q 'the log of phase 2' '$out'"
expect "the server is asked once only, after phase 1, and phase 3 does not run" \
    sh -c "[ \"\$(grep -c 'go:v1 curl' '$dir/log')\" -eq 1 ] && ! grep -q 'package-test-steps.sh phase3' '$dir/log'"

use_case phase3_fails
expect "a failing phase 3 fails the system" failed_status
expect "the failing step is named with its number" holds "FAIL deb $debian (step 9)"
expect "the logs of all three phases are printed" sh -c "grep -q 'the log of phase 1' '$out' && grep -q 'the log of phase 2' '$out' && grep -q 'the log of phase 3' '$out'"

use_case outside_fails_after_1
expect "a server that does not answer from outside after phase 1 fails the system" failed_status
expect "the step is named" holds "FAIL deb $debian (step 5)"
expect "the line says what was asked, from where, and what came back" \
    holds "step 5: server: answers 200 on /api/v1/health from outside, after phase 1: https://172.17.0.2:8480/api/v1/health gave 000"
expect "the container is not restarted, and no later phase runs" \
    sh -c "! grep -q 'docker restart' '$dir/log' && ! grep -q 'package-test-steps.sh phase2' '$dir/log'"
expect "the output is collected all the same" sh -c "grep -q 'docker cp' '$dir/log'"

use_case outside_fails_after_2
expect "a server that does not answer from outside after the restart fails the system" failed_status
expect "the step is named, with the phase" holds "step 5: server: answers 200 on /api/v1/health from outside, after phase 2: https://172.17.0.2:8480/api/v1/health gave 000"
expect "phase 3 does not run" no_call "package-test-steps.sh phase3"

use_case outside_wrong_status
expect "another answer than 200 fails the system" failed_status
expect "the status is shown" holds "gave 503"

use_case both_outside_fails
expect "with both programs, only the server is asked from outside" sh -c "[ \"\$(grep -c 'go:v1 curl' '$dir/log')\" -eq 1 ]"
expect "its failure fails the system" failed_status

use_case restart_fails
expect "a failing restart of the container fails the system" failed_status
expect "phase 2 does not run" no_call "package-test-steps.sh phase2"

use_case no_result
expect "a system whose steps wrote no result fails" failed_status
expect "that is said" holds "no result was written"
expect "no step is named when there is none to name" sh -c "grep -qx 'FAIL deb $debian' '$out'"

use_case one_of_two_fails
expect "one failing system fails the run" failed_status
expect "the other system is still tested and passes" holds "passed: 1  failed: 1"
expect "the failing system is named" holds "failed system: deb ghcr.io/splicefs/server-ubuntu-24.04:v1.0"

use_case client_only
expect "a run of the client alone passes" passed_status
expect "the client listens on no port, so no probe container is started" no_call "go:v1 curl"
expect "the server is left out, and said" holds "server: no packages, left out"
expect "only the folder of the client is mounted" \
    sh -c "grep -q 'dist/client:/pkg/client:ro' '$dir/log' && ! grep -q 'dist/server' '$dir/log'"
expect "the steps are told to test the client only" sh -c "grep -q -e '-e PROGRAMS=client ' '$dir/log'"

use_case both
expect "a run of both programs passes" passed_status
expect "the folder of each program is mounted at /pkg/PROGRAM" \
    sh -c "grep -q 'docker run.* -v $t/cases/both/root/dist/server:/pkg/server:ro -v $t/cases/both/root/dist/client:/pkg/client:ro' '$dir/log'"
expect "the steps are told both programs, the server first" sh -c "grep -q -e '-e PROGRAMS=server client ' '$dir/log'"
expect "the system is booted once" sh -c "[ \"\$(grep -c 'docker run -d' '$dir/log')\" -eq 1 ]"
expect "each program's published file is fetched from its own folder of the site and proven" \
    sh -c "grep -q 'curl.*/server/apt/pool/main/s/splicefs-server/splicefs-server_1.2.2_amd64.deb' '$dir/log' && grep -q 'curl.*/client/apt/pool/main/s/splicefs-client/splicefs-client_1.3.9_amd64.deb' '$dir/log' && grep -q 'verify apt/pool/main/s/splicefs-client/splicefs-client_1.3.9_amd64.deb' '$dir/log'"

use_case none
expect "a run with no packages fails" failed_status
expect "both programs are said to be left out" sh -c "grep -q 'server: no packages, left out' '$out' && grep -q 'client: no packages, left out' '$out'"
expect "the failure says what to do" holds "no packages in dist/server or dist/client: run make packages first"
expect "no system is started" no_call "docker run"

use_case empty_client_folder
expect "an empty folder of a program leaves it out" holds "client: no packages, left out"
expect "the rest of the run passes" passed_status

if [ "$failed" -ne 0 ]; then
    echo "$failed package-test case(s) failed"
    exit 1
fi
echo "package-test: all cases as expected"
