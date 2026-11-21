# shellcheck shell=sh
# The checks every package format's test has in common, which run inside a system the package is
# installed in. Sourced after scripts/package-lib.sh, which says what the program is and which
# provides fail.
# What program.conf and package-lib.sh set is unknown to ShellCheck, which cannot follow them.
# shellcheck disable=SC2154

# The program $1 reports the version the package was built as.
check_version_of() {
    "$1" --version | grep -qF "$VERSION" || fail "$1 --version does not report $VERSION"
}

# Every program of the package reports the version it was built as.
check_versions() {
    for each in $programs; do
        check_version_of "$each"
    done
}

# For a package that was published before program.conf listed what it lists now: a program added
# since (the server's control program) is not in it, and the service program is in every package.
check_service_version() {
    check_version_of "$program"
}

# The links the program installs lead to a program. The here-document keeps fail in this shell;
# a pipe would run the loop in a subshell, where fail would end only the subshell.
check_links() {
    link_lines="$(package_link_list)"
    while read -r link _; do
        [ -n "$link" ] || continue
        [ -x "$link" ] || fail "$link does not lead to a program"
    done <<LINKS
$link_lines
LINKS
}

# The package ships the configuration folders, empty, and nothing else: any file there would be
# one an upgrade could overwrite.
check_config_folders() {
    [ -d "$confdir" ] || fail "$confdir is missing"
    for folder in $confsubdirs; do
        [ -d "$confdir/$folder" ] || fail "$confdir/$folder is missing"
        # The file the tests write as an administrator is not the package's.
        contents="$(find "$confdir/$folder" -mindepth 1 -maxdepth 1 ! -name "$administrator_file")"
        [ -z "$contents" ] || fail "$confdir/$folder must be empty after an install"
    done
    # ls -A is used because it lists hidden entries too; the folder holds no names that need care.
    # shellcheck disable=SC2012
    found="$(ls -A "$confdir" | sort | tr '\n' ' ')"
    expected="$(echo "$confsubdirs" | sort | tr '\n' ' ')"
    [ "$found" = "$expected" ] || fail "$confdir holds something other than its empty folders"
}

# After the package is removed none of its programs is left.
check_programs_removed() {
    for each in $programs; do
        [ ! -e "/usr/bin/$each" ] || fail "remove left $each behind"
    done
}

# The checks that only one program needs are in its own folder; a program without the file has
# none.
check_extras() {
    if [ -f "$defs/package-test-extra.sh" ]; then
        # shellcheck source=/dev/null
        . "$defs/package-test-extra.sh"
    fi
}
