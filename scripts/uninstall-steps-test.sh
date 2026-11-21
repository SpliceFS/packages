#!/bin/sh
# check: uninstall steps: the comment above the removal of both packages tells a person to leave out the one not installed, and the FreeBSD steps delete the logs
# The package managers dnf, zypper and pkg refuse a package name that is not installed, so the
# command that removes both programs fails for a person who installed one. The steps files (the
# install page shows them) say so above that command, and scripts/package-test.sh does what the
# sentence says. The sentence is the one the install page shows, word for word; when the comment
# ends with a colon, the colon takes the place of the full stop.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
sentence="Leave out the one you did not install"
failed=0

for file in "$root"/steps/uninstall-*.sh; do
    # The line above the command that names both packages.
    above="$(grep -B1 'splicefs-server splicefs-client' "$file" | head -n 1)"
    case "$above" in
        "# "*". $sentence." | "# "*". $sentence:") printf 'ok   %s\n' "$(basename "$file")" ;;
        *)
            printf 'FAIL %s: the comment above the removal lacks the sentence: %s\n' "$(basename "$file")" "$above"
            failed=$((failed + 1))
            ;;
    esac
done

# FreeBSD's daemon(8) makes the log of a service, and removing the package leaves it, so the documented
# removal deletes it with the data. The names are the ones the rc scripts write to.
pkg_steps="$root/steps/uninstall-pkg.sh"
rm_line="$(grep '^rm -rf ' "$pkg_steps")"
for rc in "$root"/programs/*/freebsd/*.rc; do
    log="$(sed -n 's/^logfile=//p' "$rc")"
    case " $rm_line " in
        *" $log "*) printf 'ok   %s deletes %s\n' "$(basename "$pkg_steps")" "$log" ;;
        *)
            printf 'FAIL %s does not delete %s, the log of %s\n' "$(basename "$pkg_steps")" "$log" "$(basename "$rc")"
            failed=$((failed + 1))
            ;;
    esac
done
case "$(grep -B1 '^rm -rf ' "$pkg_steps" | head -n 1)" in
    *" the logs "*) printf 'ok   %s says that the logs are deleted\n' "$(basename "$pkg_steps")" ;;
    *)
        printf 'FAIL the comment above the deletion in %s does not say that the logs are deleted\n' "$(basename "$pkg_steps")"
        failed=$((failed + 1))
        ;;
esac

[ "$failed" -eq 0 ] || exit 1
echo "uninstall steps: all as expected"
