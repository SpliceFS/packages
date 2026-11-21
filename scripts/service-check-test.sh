#!/bin/sh
# check: service-check.sh of the server: the version the health endpoint reports is read with curl, openssl or wget
# Test of reported_version and answers in programs/server/service-check.sh. The tools it talks HTTPS
# with are stand-ins that answer as the real ones do, and the PATH holds only them and the few commands
# the check itself uses, so that the first tool the check finds is the one the case means. The stand-ins
# are written with printf, and their dollar signs are for the shell that runs them.
# shellcheck disable=SC2016
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

# The commands the check uses besides the tools: found on this machine and linked into the folder of each case.
common="sed tail head grep tr cat"
make_path() {
    mkdir -p "$work/$1"
    for tool in $common; do
        tool_path="$(command -v "$tool")"
        ln -s "$tool_path" "$work/$1/$tool"
    done
}

body='{"status":"ok","version":"v1.2.3"}'
# curl prints the body, a newline and the status code, as it does for -w '\n%{http_code}'.
make_path with-curl
printf '#!/bin/sh\nprintf "%%s\\n%%s" "$FAKE_BODY" "$FAKE_CODE"\n' >"$work/with-curl/curl"
# openssl s_client prints the whole answer, the headers first, with the line ends of HTTP.
make_path with-openssl
printf '#!/bin/sh\nprintf "HTTP/1.0 %%s OK\\r\\nContent-Type: application/json\\r\\n\\r\\n%%s\\n" "$FAKE_CODE" "$FAKE_BODY"\n' >"$work/with-openssl/openssl"
printf '#!/bin/sh\nshift\n"$@"\n' >"$work/with-openssl/timeout"
# wget prints the body of an answer with a good status and fails for any other.
make_path with-wget
printf '#!/bin/sh\n[ "$FAKE_CODE" = 200 ] && printf "%%s\\n" "$FAKE_BODY"\n' >"$work/with-wget/wget"
chmod 755 "$work"/with-*/curl "$work"/with-*/openssl "$work"/with-*/timeout "$work"/with-*/wget 2>/dev/null || true

# $1 case name, $2 the folder of tools, $3 the status code the stand-in answers, $4 the body, $5 the
# function to run, $6 the status it must end with, $7 what it must print (empty: anything).
asks() {
    shell="$(command -v sh)"
    # The script is for the shell that env starts, which reads its own $1.
    # shellcheck disable=SC2016
    got="$(env -i PATH="$work/$2" FAKE_CODE="$3" FAKE_BODY="$4" PROGRAM=server VERSION=v1.2.3 PACKAGE_DATE=20261112 \
        "$shell" -c '. scripts/package-lib.sh; . programs/server/service-check.sh
            own_address() { echo 10.0.0.5; }
            "$1"' sh "$5" 2>&1)" && status=0 || status=$?
    if [ "$status" -eq "$6" ] && { [ -z "$7" ] || [ "$got" = "$7" ]; }; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: wanted status %s and "%s", got status %s and "%s"\n' "$1" "$6" "$7" "$status" "$got"
        failed=$((failed + 1))
    fi
}

for tools in with-curl with-openssl with-wget; do
    asks "$tools: the version of an answer 200 is printed" "$tools" 200 "$body" reported_version 0 v1.2.3
    asks "$tools: an answer 503 has no version" "$tools" 503 "$body" reported_version 1 ""
    asks "$tools: an answer 200 is an answering service" "$tools" 200 "$body" answers 0 ""
    asks "$tools: an answer 503 is not" "$tools" 503 "$body" answers 1 ""
done
asks "an answer with no version prints nothing" with-curl 200 '{"status":"ok"}' reported_version 0 ""

if [ "$failed" -ne 0 ]; then
    echo "$failed service-check case(s) failed"
    exit 1
fi
echo "service-check: all cases as expected"
