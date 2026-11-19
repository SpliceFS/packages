#!/bin/sh
# check: upgrade-package.sh: a package of the same version is reinstalled, a newer one upgrades
# Test of scripts/upgrade-package-lib.sh. The package managers are stand-ins on the PATH that
# write their arguments to a file, so the test needs no Docker and runs in milliseconds (part of
# make check).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

mkdir "$work/bin" "$work/bin-dnf"
for manager in apt-get rpm zypper apk; do
    # The stand-in expands its own variables when it runs.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$manager" > "$work/bin/$manager"
    chmod 755 "$work/bin/$manager"
done
# The system that has dnf has it first, as the rpm systems of the test do.
cp "$work/bin/apt-get" "$work/bin-dnf/dnf"
sed -i.bak 's/apt-get/dnf/' "$work/bin-dnf/dnf"
rm "$work/bin-dnf/dnf.bak"

# $1 case name, $2 the folder of stand-ins that goes first on the PATH, $3 format, $4 the
# version installed, $5 the new version, $6 file or repo, $7 the one line the package manager must
# be called with.
calls() {
    : > "$work/calls"
    CALLS="$work/calls" PATH="$2:$work/bin:/usr/bin:/bin" sh -c \
        '. scripts/upgrade-package-lib.sh; upgrade_package "$@"' sh "$3" "$4" "$5" "$6" pkg-or-file
    got="$(cat "$work/calls")"
    if [ "$got" = "$7" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: want "%s" got "%s"\n' "$1" "$7" "$got"
        failed=$((failed + 1))
    fi
}

calls "deb, same version: the file is reinstalled" "$work/bin" deb v1.2.3 v1.2.3 file \
    "apt-get install -y -qq --reinstall pkg-or-file"
calls "deb, same version: the repository package is reinstalled" "$work/bin" deb v1.2.3 v1.2.3 repo \
    "apt-get install -y -qq --reinstall pkg-or-file"
calls "deb, newer version: the file is installed over the old one" "$work/bin" deb v1.2.3 v1.2.4 file \
    "apt-get install -y -qq pkg-or-file"
calls "deb, newer version: the repository package is upgraded" "$work/bin" deb v1.2.3 v1.2.4 repo \
    "apt-get install -y -qq --only-upgrade pkg-or-file"

calls "rpm, same version: the file is replaced by rpm itself" "$work/bin-dnf" rpm v1.2.3 v1.2.3 file \
    "rpm -U --replacepkgs --nosignature pkg-or-file"
calls "rpm with dnf, same version: the repository package is reinstalled" "$work/bin-dnf" rpm v1.2.3 v1.2.3 repo \
    "dnf reinstall -y -q pkg-or-file"
calls "rpm with zypper, same version: the repository package is reinstalled" "$work/bin" rpm v1.2.3 v1.2.3 repo \
    "zypper --non-interactive install --force pkg-or-file"
calls "rpm with dnf, newer version: the file is installed" "$work/bin-dnf" rpm v1.2.3 v1.2.4 file \
    "dnf install -y -q --nogpgcheck pkg-or-file"
calls "rpm with zypper, newer version: the file is installed" "$work/bin" rpm v1.2.3 v1.2.4 file \
    "zypper --non-interactive --quiet install --allow-unsigned-rpm pkg-or-file"
calls "rpm with dnf, newer version: the repository package is upgraded" "$work/bin-dnf" rpm v1.2.3 v1.2.4 repo \
    "dnf upgrade -y -q pkg-or-file"
calls "rpm with zypper, newer version: the repository package is upgraded" "$work/bin" rpm v1.2.3 v1.2.4 repo \
    "zypper --non-interactive update pkg-or-file"

calls "apk, same version: the repository package is reinstalled" "$work/bin" apk v1.2.3 v1.2.3 repo \
    "apk fix -q --reinstall pkg-or-file"
calls "apk, same version: the file is added again" "$work/bin" apk v1.2.3 v1.2.3 file \
    "apk add -q --allow-untrusted pkg-or-file"
calls "apk, newer version: the file is added over the old one" "$work/bin" apk v1.2.3 v1.2.4 file \
    "apk add -q --allow-untrusted pkg-or-file"
calls "apk, newer version: the repository package is upgraded" "$work/bin" apk v1.2.3 v1.2.4 repo \
    "apk add -q -u pkg-or-file"

[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
echo "upgrade package: all cases as expected"
