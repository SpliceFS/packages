#!/bin/sh
# Prints the state of the system it runs in, for the lifecycle test to compare before and after:
# every path of the root filesystem, then the checksum of every regular file under /etc. The
# paths named in scripts/lifecycle-excluded are left out, except that a log file of SpliceFS is
# listed although /var/log is left out. Other filesystems (the mounts of the test, /proc, the
# temporary folders) are not visited. Runs as root inside a container, so it uses only what a
# minimal system has: find, sort, awk and sha256sum.
set -eu

excluded="$(awk '!/^#/ && NF { print $1 }' "$(dirname "$0")/lifecycle-excluded")"

# A listed path is left out with everything below it; the slash is part of the match, so another
# folder that starts with the same letters stays. A listed path that ends in * is a name that
# only starts that way (the folders systemd names at random): it is left out with what is below.
paths() {
    find / -xdev -print | LC_ALL=C sort | EXCLUDED="$excluded" awk '
        BEGIN { n = split(ENVIRON["EXCLUDED"], entry, "\n") }
        {
            for (i = 1; i <= n; i++) {
                if (substr(entry[i], length(entry[i])) == "*") {
                    if (index($0, substr(entry[i], 1, length(entry[i]) - 1)) == 1) next
                } else if (index($0, entry[i] "/") == 1) next
            }
            print
        }'
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
# The logs are left out as a folder because the system writes them while it runs, but a log that
# a SpliceFS service wrote is part of what an uninstall has to take away.
echo "== logs of SpliceFS"
find /var/log -name '*splicefs*' -print | LC_ALL=C sort
