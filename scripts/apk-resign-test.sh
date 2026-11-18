#!/bin/sh
# Checks scripts/apk-resign.sh on the Alpine packages in dist/PROGRAM: signed again with a key the
# package was not made with, apk accepts every package when it trusts that key and refuses it
# when it does not, the content is the one it was, and a file that is not a signed Alpine package
# is refused. Runs on the host (make apk-resign-test; CI runs it in the Alpine jobs of
# test-packages.yml) and needs Docker.
# The key is made new for each run, in a folder of dist that is removed at the end.
# Environment: PROGRAM. Inside the apk-build image the script is called as: apk-resign-test.sh inside
set -eu

if [ "${1:-}" = inside ]; then
    status=0
    check() {
        # $1 is the name of the check, the rest is the command, which must succeed.
        name="$1"
        shift
        if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; status=1; fi
    }
    refused() {
        name="$1"
        shift
        if "$@" >/dev/null 2>&1; then echo "FAIL $name"; status=1; else echo "ok   $name"; fi
    }
    openssl genrsa -out /keys/splicefs.rsa 2048 2>/dev/null
    openssl rsa -in /keys/splicefs.rsa -pubout -out /keys/splicefs.rsa.pub 2>/dev/null
    mkdir -p /tmp/trusted /tmp/untrusted
    cp /keys/splicefs.rsa.pub /tmp/trusted/

    # Every package of dist/PROGRAM, under the folder layout the script reads.
    for pkg in /packages/alpine/*/*.apk; do
        cpu="$(basename "$(dirname "$pkg")")"
        mkdir -p "/tmp/out/alpine/$cpu"
        cp "$pkg" "/tmp/out/alpine/$cpu/"
        tar -tzvf "$pkg" | grep -v '\.SIGN\.' | sort > "/tmp/listing-$cpu"
    done
    for pkg in /tmp/out/alpine/*/*.apk; do
        refused "before: $pkg is not trusted" apk --keys-dir /tmp/trusted verify "$pkg"
    done

    check "apk-resign.sh signs every package" sh scripts/apk-resign.sh /tmp/out
    for pkg in /tmp/out/alpine/*/*.apk; do
        cpu="$(basename "$(dirname "$pkg")")"
        check "after: $pkg is accepted with the key" apk --keys-dir /tmp/trusted verify "$pkg"
        refused "after: $pkg is refused without the key" apk --keys-dir /tmp/untrusted verify "$pkg"
        tar -tzvf "$pkg" | grep -v '\.SIGN\.' | sort > "/tmp/after-$cpu"
        check "after: $pkg lists the same files" cmp "/tmp/listing-$cpu" "/tmp/after-$cpu"
    done

    # The same script run again must still give a package apk accepts: the first signature is gone.
    check "a package signed twice: signing" sh scripts/apk-resign.sh /tmp/out
    for pkg in /tmp/out/alpine/*/*.apk; do
        check "a package signed twice: $pkg is accepted" apk --keys-dir /tmp/trusted verify "$pkg"
    done

    mkdir -p /tmp/bad/alpine/x
    printf 'not a package\n' > /tmp/bad/alpine/x/text.apk
    refused "text is refused" sh scripts/apk-resign.sh /tmp/bad
    rm /tmp/bad/alpine/x/text.apk
    first="$(find /tmp/out/alpine -name '*.apk' | head -n 1)"
    head -c 4000 "$first" > /tmp/bad/alpine/x/cut.apk
    refused "a package cut short is refused" sh scripts/apk-resign.sh /tmp/bad
    rm /tmp/bad/alpine/x/cut.apk
    refused "a folder without packages is refused" sh scripts/apk-resign.sh /tmp/bad
    exit "$status"
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
: "${PROGRAM:?PROGRAM is not set}"
image="${APK_IMAGE:-ghcr.io/splicefs/apk-build:v1}"
keys="$(mktemp -d "$root/dist/apk-resign-test.XXXXXX")"
trap 'rm -rf "$keys"' EXIT
host_uid="$(id -u)"
host_gid="$(id -g)"
docker run --rm --user "$host_uid:$host_gid" -v "$keys":/keys -v "$root/dist/$PROGRAM":/packages:ro \
    -v "$root":/repo:ro -w /repo "$image" sh scripts/apk-resign-test.sh inside
