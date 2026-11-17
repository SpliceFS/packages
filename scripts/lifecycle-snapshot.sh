#!/bin/sh
# Prints the state of the system it runs in, for the lifecycle test to compare before and after:
# every path of the root filesystem, then the checksum of every regular file under /etc. The
# paths named in scripts/lifecycle-excluded are left out. Other filesystems (the mounts of the
# test, /proc, the temporary folders) are not visited. Runs as root inside a container, so it
# uses only what a minimal system has: find, sort, awk and sha256sum.
set -eu

excluded="$(awk '!/^#/ && NF { print $1 }' "$(dirname "$0")/lifecycle-excluded")"

# index() finds the folder and everything below it, not another folder that starts with the
# same letters, because the slash is part of the pattern.
paths() {
    find / -xdev -print | LC_ALL=C sort | EXCLUDED="$excluded" awk '
        BEGIN { n = split(ENVIRON["EXCLUDED"], prefix, "\n") }
        { for (i = 1; i <= n; i++) if (index($0, prefix[i] "/") == 1) next; print }'
}

all_paths="$(paths)"
echo "== paths"
printf '%s\n' "$all_paths"
echo "== checksums of /etc"
printf '%s\n' "$all_paths" | while read -r path; do
    case "$path" in
        /etc/*) if [ -f "$path" ] && [ ! -L "$path" ]; then sha256sum "$path"; fi ;;
        *) ;;
    esac
done
