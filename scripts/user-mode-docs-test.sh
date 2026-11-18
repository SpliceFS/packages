#!/bin/sh
# Tests, on the host and without Docker, what "Run as yourself" needs from the packaging and the
# documents (part of make check). A user can only run the client if the system's own FUSE helper
# is there, so the client packages must depend on fuse3; and what the user needs from the system
# (the FreeBSD sysctl, group and devfs rule) belongs to the administrator, so no package may set
# it. The README must show the FreeBSD commands. The commands of the Linux part are the files
# steps/user-mode-*.sh, which make check compares with the README and scripts/user-mode-test.sh
# runs as an ordinary user.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
failed=0

# $1 what is tested, $2 the text wanted, $3 the text that must hold it.
holds() {
    if printf '%s\n' "$3" | grep -qF -e "$2"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: "%s" is missing\n' "$1" "$2"
        failed=$((failed + 1))
    fi
}

# $1 what is tested, $2 the pattern that must not occur in the files that follow.
absent() {
    what="$1"
    pattern="$2"
    shift 2
    if grep -rEn -e "$pattern" "$@" >/dev/null 2>&1; then
        printf 'FAIL %s: found\n' "$what"
        grep -rEn -e "$pattern" "$@" | sed 's/^/        /'
        failed=$((failed + 1))
    else
        printf 'ok   %s\n' "$what"
    fi
}

deb_control="$(cat programs/client/deb/control)"
rpm_spec="$(cat programs/client/rpm/splicefs-client.spec)"
apkbuild="$(cat programs/client/alpine/APKBUILD)"
holds "the deb package depends on fuse3" "Depends: fuse3" "$deb_control"
holds "the rpm package requires fuse3" "Requires:       fuse3" "$rpm_spec"
holds "the Alpine package depends on fuse3" 'depends="fuse3"' "$apkbuild"

# The administrator's settings are never made by a package: not the FUSE helper's mode, not the
# FreeBSD sysctl, group or devfs rule.
absent "no client package file sets what a user needs from the system" \
    'usermount|fusermount|sysctl|devfs|chmod u\+s|operator' programs/client packaging/service

# The client finds the folders of an ordinary user by itself (client 0.5.36), so the commands name
# neither a configuration folder nor a cache folder.
absent "the commands of a user need no --config and no cache.dir" \
    '--config|cache' steps/user-mode-start.sh steps/user-mode-use.sh

readme="$(cat README.md)"
for command in \
    "sysctl vfs.usermount=1" \
    "echo 'vfs.usermount=1' >> /etc/sysctl.conf" \
    "sysrc kld_list+=fusefs && kldload fusefs" \
    "pw groupmod operator -m alice" \
    "add path fuse mode 0660 group operator" \
    "sysrc devfs_system_ruleset=fuse_users && service devfs restart" \
    "modprobe fuse"; do
    holds "README.md says: $command" "$command" "$readme"
done

[ "$failed" -eq 0 ]
