# shellcheck shell=sh
# The test configuration of the server: one share and one user, written the way docs/configuration.md
# of the server says (a share is a file in shares.d, a user is a file in the state folder), and
# checked where the documentation says it is. Sourced inside a system the package is installed in
# (scripts/package-test.sh, through scripts/system-state-lib.sh), after scripts/package-lib.sh, which
# says where the configuration and the data are (confdir, datadir). The functions read those
# variables when they run, so a test can move them.
# shellcheck disable=SC2154
# shellcheck source=service-check.sh
. "$defs/service-check.sh"

share_name=media
# The folder the share serves is the test's own, outside what the package owns, so
# remove_test_data takes it away again.
share_dir=/srv/media
share_file=hello.txt
share_text=hello
user_name=alice
user_password=secret

# Writes the share, its folder with one file, and the user. The service must be able to write
# below shared/ (its keys and its node file) and to read the user file, and it is not running yet,
# so nothing has given the folders made here to it.
write_test_config() {
    mkdir -p "$share_dir" "$confdir/shares.d" "$datadir/shared/users"
    printf '%s\n' "$share_text" >"$share_dir/$share_file"
    printf 'path: %s\n' "$share_dir" >"$confdir/shares.d/$share_name.yaml"
    password_hash="$(printf '%s\n' "$user_password" | splicefsdctl hash-password)" ||
        fail "splicefsdctl hash-password failed"
    printf 'password_hash: "%s"\nshares: [%s]\n' "$password_hash" "$share_name" \
        >"$datadir/shared/users/$user_name.yaml"
    chown -R "$expected_user" "$datadir/shared"
}

# The files are where the documentation says they are, with what the documentation says they hold.
check_test_config() {
    share_conf="$confdir/shares.d/$share_name.yaml"
    user_conf="$datadir/shared/users/$user_name.yaml"
    [ -f "$share_conf" ] || fail "$share_conf is missing"
    grep -qxF "path: $share_dir" "$share_conf" || fail "$share_conf does not name the folder $share_dir"
    [ -f "$user_conf" ] || fail "$user_conf is missing"
    # The dollar signs are the text of the hash, so the quotes are single on purpose.
    # shellcheck disable=SC2016
    grep -q '^password_hash: "\$argon2id\$' "$user_conf" || fail "$user_conf holds no argon2id hash"
    grep -qxF "shares: [$share_name]" "$user_conf" || fail "$user_conf does not allow the share $share_name"
    [ -f "$share_dir/$share_file" ] || fail "$share_dir/$share_file is missing"
}

# What the test made outside the folders the documented removal deletes.
remove_test_data() {
    rm -rf "$share_dir"
}
