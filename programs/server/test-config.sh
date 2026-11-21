# shellcheck shell=sh
# The test configuration of the server: one share and one user, written the way docs/configuration.md
# of the server says (a share is a file in shares.d, a user is a file in the state folder, made by
# splicefsdctl user add when the release has it), and checked where the documentation says it is. Sourced inside a system the package is installed in
# (scripts/package-test-steps.sh, through scripts/system-state-lib.sh), after scripts/package-lib.sh, which
# says where the configuration and the data are (confdir, datadir). The functions read those
# variables when they run, so a test can move them.
# shellcheck disable=SC2154
# shellcheck source=service-check.sh
. "$defs/service-check.sh"

# shellcheck source=../../scripts/test-config-lib.sh
. scripts/test-config-lib.sh

# The file of the configuration folder the test writes, which the file checks of the package leave out.
test_config_file=$share_name.yaml
# The folder the share serves is the test's own, outside what the package owns, so
# remove_test_data takes it away again, with the folders above it that the test had to make.
share_dir=/srv/media

# Makes the user. A release whose splicefsdctl has user add makes the file itself, named by a new
# user id; an earlier release read a file named by the user name, so that file is written here, with
# the hash that hash-password prints. Either way the file is the one the documentation of that
# release describes.
write_test_user() {
    if splicefsdctl user add --help >/dev/null 2>&1; then
        printf '%s\n' "$user_password" |
            splicefsdctl user add --state "$datadir" --share "$share_name" "$user_name" >/dev/null ||
            fail "splicefsdctl user add failed"
        return 0
    fi
    password_hash="$(printf '%s\n' "$user_password" | splicefsdctl hash-password)" ||
        fail "splicefsdctl hash-password failed"
    printf 'password_hash: "%s"\nshares: [%s]\n' "$password_hash" "$share_name" \
        >"$datadir/shared/users/$user_name.yaml"
}

# Prints the file of the user: the one that holds the name, as user add makes it, or else the one
# named by the name, as earlier releases read it. Prints nothing when there is neither.
find_test_user_file() {
    users_dir="$datadir/shared/users"
    found="$(grep -lxF "name: $user_name" "$users_dir"/*.yaml 2>/dev/null | head -n 1)"
    if [ -n "$found" ]; then
        echo "$found"
    elif [ -f "$users_dir/$user_name.yaml" ]; then
        echo "$users_dir/$user_name.yaml"
    fi
}

# Writes the share, its folder with one file, and the user. The service must be able to write
# below shared/ (its keys and its node file) and to read the user file, and it is not running yet,
# so nothing has given the folders made here to it.
write_test_config() {
    make_test_folder "$share_dir"
    # shared/cluster is for the cluster key: splicefsdctl cluster init gives the key file the owner of that folder,
    # so the folder must be there, and until the server has run nothing has made it.
    mkdir -p "$confdir/shares.d" "$datadir/shared/users" "$datadir/shared/cluster"
    printf '%s\n' "$share_text" >"$share_dir/$share_file"
    printf 'path: %s\n' "$share_dir" >"$confdir/shares.d/$test_config_file"
    write_test_user
    chown -R "$expected_user" "$datadir/shared"
}

# The files are where the documentation says they are, with what the documentation says they hold.
check_test_config() {
    share_conf="$confdir/shares.d/$test_config_file"
    user_conf="$(find_test_user_file)"
    [ -f "$share_conf" ] || fail "$share_conf is missing"
    grep -qxF "path: $share_dir" "$share_conf" || fail "$share_conf does not name the folder $share_dir"
    [ -n "$user_conf" ] || fail "no file in $datadir/shared/users is the user $user_name"
    # The dollar signs are the text of the hash, so the quotes are single on purpose. The hash is
    # in quotes in the file written here and without them in the file user add writes.
    # shellcheck disable=SC2016
    grep -Eq '^password_hash: "?\$argon2id\$' "$user_conf" || fail "$user_conf holds no argon2id hash"
    grep -qxF "shares: [$share_name]" "$user_conf" || fail "$user_conf does not allow the share $share_name"
    [ -f "$share_dir/$share_file" ] || fail "$share_dir/$share_file is missing"
}

# What the test made outside the folders the documented removal deletes: the share folder, and the
# folders above it that were not there before the test.
remove_test_data() {
    rm -rf "$share_dir"
    remove_made_folders
}
